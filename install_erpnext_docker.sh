#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# This script prepares an Ubuntu 24.04 host for running ERPNext via Docker.
# It installs Docker Engine + Compose plugin, fetches the frappe_docker stack
# and seeds configuration files so you can review them before starting.
#
# Usage:
#   sudo ./install_erpnext_docker.sh \
#     --project-root /opt/erpnext \
#     --project-name erpnext \
#     --erpnext-branch version-15 \
#     --site erp.example.com \
#     --admin-password 'SafeAdminPassw0rd' \
#     --db-root-password 'SafeDbRootPassw0rd' \
#     --db-password 'SafeDbUserPassw0rd'
#
# Any option can be omitted to accept defaults (see DEFAULT_* variables below).

DEFAULT_PROJECT_ROOT="/opt/erpnext"
DEFAULT_PROJECT_NAME="erpnext"
DEFAULT_BRANCH="version-15"
DEFAULT_SITE="erp.ib-weixdorf"
DEFAULT_ADMIN_PASSWORD="master999"  # default admin password (update after first login)
DEFAULT_DB_ROOT_PASSWORD="master999"
DEFAULT_DB_PASSWORD="master999"
DEFAULT_LETSENCRYPT_EMAIL=""

usage() {
  cat <<USAGE
Usage: sudo ./install_erpnext_docker.sh [options]

Options:
  --project-root PATH        Zielverzeichnis für die Docker-Stacks (Default: ${DEFAULT_PROJECT_ROOT})
  --project-name NAME        Compose-Projektname (Default: ${DEFAULT_PROJECT_NAME})
  --erpnext-branch BRANCH    Git-Branch oder Tag von frappe/frappe_docker (Default: ${DEFAULT_BRANCH})
  --site FQDN                Primäre ERPNext-Site / Domain (Default: ${DEFAULT_SITE})
  --admin-password PASS      Administrator-Passwort für neue Site (optional)
  --db-root-password PASS    MariaDB-Root-Passwort (optional)
  --db-password PASS         MariaDB-Passwort für ERPNext-Benutzer (optional)
  --letsencrypt-email MAIL   E-Mail für Let's Encrypt (für Traefik, optional)
  -h, --help                 Diese Hilfe anzeigen
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Dieses Skript muss mit root-Rechten (sudo) laufen." >&2
    exit 1
  fi
}

parse_args() {
  PROJECT_ROOT="${DEFAULT_PROJECT_ROOT}"
  PROJECT_NAME="${DEFAULT_PROJECT_NAME}"
  ERP_BRANCH="${DEFAULT_BRANCH}"
  ERP_SITE="${DEFAULT_SITE}"
  ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD}"
  DB_ROOT_PASSWORD="${DEFAULT_DB_ROOT_PASSWORD}"
  DB_PASSWORD="${DEFAULT_DB_PASSWORD}"
  LETSENCRYPT_EMAIL="${DEFAULT_LETSENCRYPT_EMAIL}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root)
        PROJECT_ROOT="$2"; shift 2 ;;
      --project-name)
        PROJECT_NAME="$2"; shift 2 ;;
      --erpnext-branch)
        ERP_BRANCH="$2"; shift 2 ;;
      --site)
        ERP_SITE="$2"; shift 2 ;;
      --admin-password)
        ADMIN_PASSWORD="$2"; shift 2 ;;
      --db-root-password)
        DB_ROOT_PASSWORD="$2"; shift 2 ;;
      --db-password)
        DB_PASSWORD="$2"; shift 2 ;;
      --letsencrypt-email)
        LETSENCRYPT_EMAIL="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "[ERROR] Unbekannte Option: $1" >&2
        usage
        exit 1 ;;
    esac
  done
}

check_requirements() {
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y lsb-release
  fi

  local ubuntu_version
  ubuntu_version=$(lsb_release -rs)
  if [[ "${ubuntu_version}" != 24.* ]]; then
    echo "[WARN] Dieses Skript wurde für Ubuntu 24.x getestet. Aktuell: ${ubuntu_version}" >&2
  fi
}

install_packages() {
  echo "[INFO] Installiere benötigte Pakete..."
  apt-get update -y
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    software-properties-common \
    git
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker bereits installiert, überspringe."
    return
  fi

  echo "[INFO] Installiere Docker Engine und Compose Plugin..."
  install_packages

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local codename
  codename=$(lsb_release -cs)
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "${SUDO_USER}"
    echo "[INFO] Benutzer ${SUDO_USER} wurde der docker-Gruppe hinzugefügt (erneutes Einloggen erforderlich)."
  fi
}

prepare_project_root() {
  mkdir -p "${PROJECT_ROOT}"
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${PROJECT_ROOT}"
}

clone_frappe_repo() {
  local target_dir="${PROJECT_ROOT}/frappe_docker"
  if [[ -d "${target_dir}/.git" ]]; then
    echo "[INFO] frappe_docker existiert bereits, hole Updates..."
    git -C "${target_dir}" fetch --all --prune
    git -C "${target_dir}" checkout "${ERP_BRANCH}"
    git -C "${target_dir}" pull --ff-only origin "${ERP_BRANCH}"
  else
    echo "[INFO] Klone frappe/frappe_docker (${ERP_BRANCH})..."
    git clone --branch "${ERP_BRANCH}" --depth 1 https://github.com/frappe/frappe_docker.git "${target_dir}"
  fi
}

seed_env_file() {
  local env_path="${PROJECT_ROOT}/frappe_docker/.env"
  if [[ ! -f "${env_path}" ]]; then
    echo "[INFO] Lege .env aus Vorlage an..."
    if [[ -f "${PROJECT_ROOT}/frappe_docker/env-production-example" ]]; then
      cp "${PROJECT_ROOT}/frappe_docker/env-production-example" "${env_path}"
    else
      curl -fsSL https://raw.githubusercontent.com/frappe/frappe_docker/${ERP_BRANCH}/env-production-example -o "${env_path}"
    fi
  fi

  {
    echo ""
    echo "# --- Werte von install_erpnext_docker.sh (${PROJECT_NAME}) ---"
    echo "COMPOSE_PROJECT_NAME=${PROJECT_NAME}"
    echo "ERPNEXT_SITE=${ERP_SITE}"
    echo "SITES=${ERP_SITE}"
    if [[ -n "${ADMIN_PASSWORD}" ]]; then
      echo "ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    fi
    if [[ -n "${DB_ROOT_PASSWORD}" ]]; then
      echo "MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
      echo "MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
      echo "DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}"
    fi
    if [[ -n "${DB_PASSWORD}" ]]; then
      echo "DB_PASSWORD=${DB_PASSWORD}"
    fi
    if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
      echo "LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}"
    fi
  } >> "${env_path}"

  chmod 640 "${env_path}"
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${env_path}"
}

write_override_file() {
  local override_path="${PROJECT_ROOT}/frappe_docker/docker-compose.override.yml"
  if [[ -f "${override_path}" ]]; then
    echo "[INFO] docker-compose.override.yml existiert bereits, überspringe." >&2
    return
  fi

  cat <<OVERRIDE > "${override_path}"
# Dieses Override sorgt dafür, dass der interne ERPNext-Nginx nur auf localhost
# veröffentlicht wird. So kann ein externer Nginx-Proxy die Weiterleitung übernehmen.
services:
  frontend:
    ports:
      - "127.0.0.1:8080:8080"
  backend:
    environment:
      FRAPPE_SITE_NAME_HEADER: ${ERPNEXT_SITE}
OVERRIDE

  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${override_path}"
}

print_next_steps() {
  cat <<NEXT

[INFO] Basis-Setup abgeschlossen.

Nächste Schritte:
 1. Prüfe und ergänze die Datei ${PROJECT_ROOT}/frappe_docker/.env (Passwörter, Mail, Ports).
 2. Erstelle die ERPNext-Site und Datenbank:
      cd ${PROJECT_ROOT}/frappe_docker
      docker compose --profile production pull
      docker compose --profile production up -d
      docker compose exec backend bench new-site ${ERP_SITE} \\
         --admin-password "${ADMIN_PASSWORD}" --db-password "${DB_PASSWORD}"
      docker compose exec backend bench install-app erpnext
 3. Verbinde deinen externen Nginx mit http://127.0.0.1:8080 (Beispiel-Konfiguration siehe README).
 4. Für SSL nutze deinen Host-Nginx oder einen vorgeschalteten Load-Balancer.

Hinweis: Benutzer ${SUDO_USER:-root} muss sich ggf. einmal neu anmelden, damit die docker-Gruppe aktiv wird.
NEXT
}

main() {
  require_root
  parse_args "$@"
  check_requirements
  install_packages
  install_docker
  prepare_project_root
  clone_frappe_repo
  seed_env_file
  write_override_file
  print_next_steps
}

main "$@"
