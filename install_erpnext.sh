#!/bin/bash

# ======================================================================================
# Konfigurationsblock: Bitte passen Sie die folgenden Variablen an Ihre Bedürfnisse an.
# ======================================================================================

FRAPPE_USER="frappe"
FRAPPE_USER_PASSWORD="Passwort hier eintragen"
SITE_NAME="Name der Seite hier eintragen erp.meine-seite.de"
MARIADB_ROOT_PASSWORD="Passwort hier eintragen"
ADMIN_PASSWORD="Passwort hier eintragen"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"

# ======================================================================================
# Ende des Konfigurationsblocks. Ab hier keine Änderungen mehr vornehmen.
# ======================================================================================
# Stoppt das Skript bei Fehlern
set -e

# Stelle sicher, dass das Skript mit Root-Rechten läuft. Wenn nicht, erneut mit sudo starten.
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
        SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
        echo "Root-Rechte werden benötigt – starte Skript erneut mit sudo..."
        exec sudo bash "$SCRIPT_PATH" "$@"
    else
        echo "Dieses Skript muss als Root ausgeführt werden." >&2
        exit 1
    fi
fi


# Server-IP automatisch ermitteln, falls nicht gesetzt
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk "{print $1}")
fi

# --- Phase I: Umgebungseinrichtung und Installation der Abhängigkeiten ---
echo ">>> Phase I: Starte Umgebungseinrichtung und Installation der Abhängigkeiten..."

# System aktualisieren
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# Dedizierten Frappe-Benutzer erstellen
if id "$FRAPPE_USER" &>/dev/null; then
    echo "Benutzer $FRAPPE_USER existiert bereits. Überspringe Erstellung."
else
    useradd -m -s /bin/bash "$FRAPPE_USER"
    echo "$FRAPPE_USER:$FRAPPE_USER_PASSWORD" | chpasswd
    usermod -aG sudo "$FRAPPE_USER"
    echo "$FRAPPE_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

# Notwendige Pakete installieren
apt-get install -y git python3-dev python3-setuptools python3-pip python3.12-venv \
                   software-properties-common mariadb-server mariadb-client \
                   redis-server nginx supervisor ansible curl xvfb libfontconfig wkhtmltopdf \
                   libmysqlclient-dev

# pip für Root so konfigurieren, dass systemweite Pakete installiert werden dürfen (PEP 668)
mkdir -p /root/.config/pip
cat > /root/.config/pip/pip.conf <<'PIPCONF'
[global]
break-system-packages = true
PIPCONF

echo ">>> Phase I abgeschlossen."

# --- Phase II: Automatisierte und sichere Datenbankkonfiguration ---
echo ">>> Phase II: Starte Datenbankkonfiguration..."

# Berechne den Datenbanknamen, wie es Frappe Bench tut
DB_NAME=$(python3 -c "import hashlib; print('_' + hashlib.md5('$SITE_NAME'.encode()).hexdigest()[:16])")

# MariaDB-Root-Passwort nicht-interaktiv setzen
debconf-set-selections <<< "maria-db-server mysql-server/root_password password $MARIADB_ROOT_PASSWORD"
debconf-set-selections <<< "maria-db-server mysql-server/root_password_again password $MARIADB_ROOT_PASSWORD"

# mysql_secure_installation nicht-interaktiv ausführen
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

# Bereinige eine eventuell vorhandene alte Datenbank und einen alten Benutzer
echo ">>> Bereinige eventuell vorhandene alte Datenbank für $SITE_NAME..."
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$DB_NAME'@'localhost';"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

# Root-Benutzer für Passwort-Authentifizierung konfigurieren
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD';"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

# UTF8MB4-Konfiguration anwenden
cat > /etc/mysql/mariadb.conf.d/99-erpnext.cnf << EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

# MariaDB-Dienst neu starten
systemctl restart mariadb

echo ">>> Phase II abgeschlossen."

# --- Phase III: Bereitstellung von Frappe Bench und ERPNext-Anwendung ---
echo ">>> Phase III: Starte Bereitstellung von Frappe Bench und ERPNext..."

# Wechsel zum Frappe-Benutzer für die folgenden Schritte
sudo -u "$FRAPPE_USER" bash <<EOF
set -e
cd /home/"$FRAPPE_USER"

# Node.js 18 über NVM installieren
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

# NVM für die aktuelle Shell-Sitzung laden
source "/home/$FRAPPE_USER/.nvm/nvm.sh"

# Node.js 18 installieren
nvm install 18

# Yarn installieren
npm install -g yarn

# Frappe Bench installieren (mit Workaround für Ubuntu 24.04)
pip3 install frappe-bench --break-system-packages

# PATH explizit setzen, um sowohl 'bench' als auch 'yarn' einzuschließen
NODE_VERSION=\$(nvm version)
export PATH="/home/$FRAPPE_USER/.nvm/versions/node/\$NODE_VERSION/bin:/home/$FRAPPE_USER/.local/bin:\$PATH"

# Frappe Bench initialisieren
bench init --frappe-branch "$FRAPPE_BRANCH" frappe-bench

# In das Bench-Verzeichnis wechseln
cd frappe-bench

# Neue Site erstellen
bench new-site "$SITE_NAME" --mariadb-root-password "$MARIADB_ROOT_PASSWORD" --admin-password "$ADMIN_PASSWORD"

# ERPNext-App herunterladen und installieren
bench get-app --branch "$ERPNEXT_BRANCH" erpnext
bench --site "$SITE_NAME" install-app erpnext
EOF

echo ">>> Phase III abgeschlossen."

echo ">>> Phase IV: Starte Konfiguration der Produktionsumgebung..."

# Site-Konfiguration anpassen (Host-Zuordnung, Default-Site)
FRAPPE_USER_ENV="$FRAPPE_USER" SITE_ENV="$SITE_NAME" SERVER_IP_ENV="$SERVER_IP" python3 - <<'PYCONF'
import json, os, pathlib
bench_root = pathlib.Path(f"/home/{os.environ['FRAPPE_USER_ENV']}/frappe-bench")
site = os.environ['SITE_ENV']
server_ip = os.environ.get('SERVER_IP_ENV', '').strip()
site_config_path = bench_root / 'sites' / site / 'site_config.json'
if site_config_path.exists():
    data = json.loads(site_config_path.read_text())
else:
    data = {}
data['host_name'] = site
host_map = {site: site}
if server_ip:
    host_map[server_ip] = site
data['host_name_map'] = host_map
site_config_path.write_text(json.dumps(data, indent=2))
common_path = bench_root / 'sites' / 'common_site_config.json'
if common_path.exists():
    common = json.loads(common_path.read_text())
else:
    common = {}
common['default_site'] = site
common_path.write_text(json.dumps(common, indent=2))
PYCONF

# Dateirechte für nginx vorbereiten
chmod o+rx /home/"$FRAPPE_USER"
chmod o+rx /home/"$FRAPPE_USER"/frappe-bench
find /home/"$FRAPPE_USER"/frappe-bench/sites -type d -exec chmod 755 {} \;
find /home/"$FRAPPE_USER"/frappe-bench/sites -type f -exec chmod 644 {} \;

# Supervisor-Konfiguration aus Bench übernehmen
sudo -u "$FRAPPE_USER" bash -lc 'cd ~/frappe-bench && bench setup supervisor --yes'
ln -sf /home/"$FRAPPE_USER"/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
systemctl enable --now supervisor
supervisorctl reread
supervisorctl update

# nginx-Konfiguration übernehmen und anpassen
sudo -u "$FRAPPE_USER" bash -lc 'cd ~/frappe-bench && bench setup nginx'
ln -sf /home/"$FRAPPE_USER"/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf
NGINX_CONF=$(find /etc/nginx -maxdepth 2 -name 'frappe-bench.conf' | head -n1)
if [ -n "$NGINX_CONF" ]; then
  python3 - "$NGINX_CONF" "$SITE_NAME" "$SERVER_IP" <<'PYNGINX'
import sys, pathlib, re
conf = pathlib.Path(sys.argv[1])
site = sys.argv[2]
ip = sys.argv[3].strip()
text = conf.read_text()
pattern = rf"(server_name\s+{re.escape(site)})([^;]*);"
replace = rf"\1\2;"
if ip:
    replace = rf"\1\2 {ip};"
text, count = re.subn(pattern, replace, text, count=1)
if count == 0 and ip:
    text = text.replace(f"server_name {site};", f"server_name {site} {ip};", 1)
if "listen 0.0.0.0:80;" not in text:
    text = text.replace("listen 80;", "listen 80;\n    listen 0.0.0.0:80;\n    listen 127.0.0.1:80;", 1)
conf.write_text(text)
PYNGINX
  if [ ! -f /etc/nginx/conf.d/00-logging.conf ]; then
    cat <<'LOGFMT' >/etc/nginx/conf.d/00-logging.conf
log_format main '$remote_addr - $remote_user [$time_local] "$request" ' \
                '$status $body_bytes_sent "$http_referer" ' \
                '"$http_user_agent" "$http_x_forwarded_for"';
LOGFMT
  fi
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Supervisor-Dienste neu starten
supervisorctl restart all

# Berechtigungen für den Bench-Baum vereinheitlichen
chown -R "$FRAPPE_USER":"$FRAPPE_USER" /home/"$FRAPPE_USER"

echo ">>> Phase IV abgeschlossen."
echo "=========================================================================="
echo "ERPNext-Installation erfolgreich abgeschlossen!"
echo "Ihre Site ist erreichbar unter: http://$SITE_NAME"
echo "Login-Benutzer: Administrator"
echo "Passwort: Das von Ihnen in der Variable ADMIN_PASSWORD festgelegte Passwort."
echo "=========================================================================="


