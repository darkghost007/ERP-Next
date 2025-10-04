#!/bin/bash

# ======================================================================================
# Konfigurationsblock: Bitte passen Sie die folgenden Variablen an Ihre Bedürfnisse an.
# ======================================================================================

FRAPPE_USER="frappe"
FRAPPE_USER_PASSWORD="IhrSicheresLinuxPasswort"
SITE_NAME="erp.beispiel.com"
MARIADB_ROOT_PASSWORD="IhrSicheresDbRootPasswort"
ADMIN_PASSWORD="IhrSicheresERPNextAdminPasswort"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"

# ======================================================================================
# Ende des Konfigurationsblocks. Ab hier keine Änderungen mehr vornehmen.
# ======================================================================================

# Stoppt das Skript bei Fehlern
set -e

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
                   redis-server nginx curl xvfb libfontconfig wkhtmltopdf libmysqlclient-dev

echo ">>> Phase I abgeschlossen."

# --- Phase II: Automatisierte und sichere Datenbankkonfiguration ---
echo ">>> Phase II: Starte Datenbankkonfiguration..."

# MariaDB-Root-Passwort nicht-interaktiv setzen
debconf-set-selections <<< "maria-db-server mysql-server/root_password password $MARIADB_ROOT_PASSWORD"
debconf-set-selections <<< "maria-db-server mysql-server/root_password_again password $MARIADB_ROOT_PASSWORD"

# mysql_secure_installation nicht-interaktiv ausführen
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
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
export NVM_DIR="/home/$FRAPPE_USER/.nvm"
 && \. "\$NVM_DIR/nvm.sh"
nvm install 18

# Yarn installieren
npm install -g yarn

# Frappe Bench installieren (mit Workaround für Ubuntu 24.04)
pip3 install frappe-bench --break-system-packages

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

# --- Phase IV: Konfiguration der Produktionsumgebung ---
echo ">>> Phase IV: Starte Konfiguration der Produktionsumgebung..."

# Wechsel in das Bench-Verzeichnis als root, um Produktions-Setup auszuführen
cd /home/"$FRAPPE_USER"/frappe-bench

# Produktionsdienste einrichten (Supervisor und Nginx)
bench setup production "$FRAPPE_USER"
bench setup nginx

# Supervisor neu starten, um die Konfiguration zu laden
supervisorctl restart all

# Berechtigungen korrigieren
chown -R "$FRAPPE_USER":"$FRAPPE_USER" /home/"$FRAPPE_USER"

echo ">>> Phase IV abgeschlossen."
echo "=========================================================================="
echo "ERPNext-Installation erfolgreich abgeschlossen!"
echo "Ihre Site ist erreichbar unter: http://$SITE_NAME"
echo "Login-Benutzer: Administrator"
echo "Passwort: Das von Ihnen in der Variable ADMIN_PASSWORD festgelegte Passwort."
echo "=========================================================================="
