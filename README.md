# ERP-Next Bereitstellungsskript

Dieses Repository enthält das Skript [`install_erpnext.sh`](install_erpnext.sh),
mit dem du eine vollständige ERPNext-Instanz auf einem Ubuntu-24.04-Server
bereitstellen kannst. Das Skript richtet alle benötigten Komponenten (MariaDB,
Redis, Node.js, Bench, ERPNext) ein und führt das Produktionssetup aus.

## Anleitung

1. Repository klonen:
   ```bash
   git clone https://github.com/darkghost007/ERP-Next.git
   cd ERP-Next
   ```
2. Skript ausführbar machen:
   ```bash
   chmod +x install_erpnext.sh
   ```
3. Optional: Konfigurationsvariablen im Kopf der Datei anpassen
   (Benutzername, Passwörter, Site-Domain, Branches).
4. Skript als root bzw. via sudo starten:
   ```bash
   sudo ./install_erpnext.sh
   ```
5. Nach Abschluss ist die Bench unter `/home/frappe/frappe-bench` verfügbar.
   Der Administrator-Login entspricht dem im Skript gesetzten `ADMIN_PASSWORD`.

> Hinweis: Das Skript erstellt standardmäßig den Benutzer `frappe` und setzt
> sichere Standardpasswörter. Für produktive Umgebungen unbedingt anpassen und
> anschließend SMTP/SSL-Konfiguration sowie Backups einrichten.


Für einen externen NGIX:

Details-Tab

Domain Names: erp....
Forward Hostname/IP: 192.168.178....
Forward Port: 80
Scheme: http
Cache Assets: aus
Block Common Exploits: an (optional)
Websockets Support: an
Custom Nginx Configuration (Advanced)

Nur die Header:

proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 120s;
SSL-Tab (falls Zertifikat):

Ein Zertifikat auswählen oder über NPM ausstellen.
„Force SSL“ aktivieren.
