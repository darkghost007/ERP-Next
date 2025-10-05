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
