#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

DEFAULT_PROJECT_ROOT="/opt/erpnext"
DEFAULT_PROJECT_NAME="erpnext"
DEFAULT_BRANCH="version-15"
DEFAULT_SITE="erp.ib-weixdorf"
DEFAULT_ADMIN_PASSWORD="master999"
DEFAULT_DB_ROOT_PASSWORD="master999"
DEFAULT_DB_PASSWORD="master999"
DEFAULT_LETSENCRYPT_EMAIL=""

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo ./install_erpnext_docker.sh [options]

Options:
  --project-root PATH        Zielverzeichnis für Docker-Stacks (Default: ${DEFAULT_PROJECT_ROOT})
  --project-name NAME        Compose-Projektname (Default: ${DEFAULT_PROJECT_NAME})
  --erpnext-branch BRANCH    Git-Branch/Tag von frappe/frappe_docker (Default: ${DEFAULT_BRANCH})
  --site FQDN                Primäre ERPNext-Site/Domain (Default: ${DEFAULT_SITE})
  --admin-password PASS      Administrator-Passwort für neue Site (Default: ${DEFAULT_ADMIN_PASSWORD})
  --db-root-password PASS    MariaDB-Root-Passwort (Default: ${DEFAULT_DB_ROOT_PASSWORD})
  --db-password PASS         MariaDB-Passwort für ERPNext-Benutzer (Default: ${DEFAULT_DB_PASSWORD})
  --letsencrypt-email MAIL   E-Mail für Let's Encrypt (optional)
  -h, --help                 Diese Hilfe anzeigen
USAGE
}

require_root() {
  [[ ${EUID} -eq 0 ]] || error "Dieses Skript muss mit root-Rechten (sudo) laufen."
}

parse_args() {
  PROJECT_ROOT=${DEFAULT_PROJECT_ROOT}
  PROJECT_NAME=${DEFAULT_PROJECT_NAME}
  ERP_BRANCH=${DEFAULT_BRANCH}
  ERP_SITE=${DEFAULT_SITE}
  ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}
  DB_ROOT_PASSWORD=${DEFAULT_DB_ROOT_PASSWORD}
  DB_PASSWORD=${DEFAULT_DB_PASSWORD}
  LETSENCRYPT_EMAIL=${DEFAULT_LETSENCRYPT_EMAIL}

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
        usage
        error "Unbekannte Option: $1" ;;
    esac
  done
}

ubuntu_codename() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -cs
  else
    . /etc/os-release
    echo "$VERSION_CODENAME"
  fi
}

check_platform() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ ${ID} != "ubuntu" ]]; then
      warn "Gefundenes System (${PRETTY_NAME}) ist kein Ubuntu. Skript wurde für Ubuntu 24.04 getestet."
    elif [[ ${VERSION_ID} != 24.* ]]; then
      warn "Ubuntu-Version ${VERSION_ID} erkannt. Skript ist für 24.x (noble) validiert."
    fi
  fi
}

ensure_packages() {
  log "Installiere Basis-Pakete..."
  apt-get update -y
  apt-get install -y apt-transport-https ca-certificates curl gnupg git software-properties-common
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get install -y lsb-release
  fi
}

remove_conflicting_docker_repos() {
  local files=()
  if [[ -d /etc/apt/sources.list.d ]]; then
    mapfile -t files < <(grep -Rl "download.docker.com/linux/debian" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)
  else
    mapfile -t files < <(grep -Rl "download.docker.com/linux/debian" /etc/apt/sources.list 2>/dev/null || true)
  fi

  if [[ ${#files[@]} -gt 0 ]]; then
    for file in "${files[@]}"; do
      [[ -f ${file} ]] || continue
      log "Entferne inkompatible Docker-Quelle: ${file}"
      rm -f "${file}"
    done
    log "Konfliktbehaftete Docker-Repositories wurden gelöscht."
  fi
}

setup_docker_repo() {
  local keyring="/etc/apt/keyrings/docker.gpg"
  local codename
  codename=$(ubuntu_codename)

  log "Konfiguriere Docker APT-Repository für Ubuntu (${codename})..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "${keyring}"
  chmod a+r "${keyring}"

  cat <<EOF >/etc/apt/sources.list.d/docker.list
deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${codename} stable
EOF
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker bereits installiert – Repository wird aktualisiert."
  else
    log "Docker wird installiert..."
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  if [[ -n ${SUDO_USER:-} ]]; then
    usermod -aG docker "${SUDO_USER}"
    log "Benutzer ${SUDO_USER} wurde der docker-Gruppe hinzugefügt (erneutes Einloggen erforderlich)."
  fi
}

prepare_project_root() {
  log "Bereite Projektverzeichnis ${PROJECT_ROOT} vor..."
  mkdir -p "${PROJECT_ROOT}"
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${PROJECT_ROOT}"
}

clone_frappe_repo() {
  local target_dir="${PROJECT_ROOT}/frappe_docker"
  if [[ -d "${target_dir}/.git" ]]; then
    log "Aktualisiere bestehendes frappe_docker Repository..."
    git -C "${target_dir}" fetch --all --prune
    git -C "${target_dir}" checkout "${ERP_BRANCH}"
    git -C "${target_dir}" pull --ff-only origin "${ERP_BRANCH}"
  else
    log "Klone frappe/frappe_docker (${ERP_BRANCH})..."
    git clone --branch "${ERP_BRANCH}" --depth 1 https://github.com/frappe/frappe_docker.git "${target_dir}"
  fi
}

set_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf "%s=%s\n" "${key}" "${value}" >>"${file}"
  fi
}

seed_env_file() {
  local env_path="${PROJECT_ROOT}/frappe_docker/.env"
  log "Erzeuge/aktualisiere ${env_path}..."

  if [[ ! -f "${env_path}" ]]; then
    if [[ -f "${PROJECT_ROOT}/frappe_docker/env-production-example" ]]; then
      cp "${PROJECT_ROOT}/frappe_docker/env-production-example" "${env_path}"
    else
      curl -fsSL "https://raw.githubusercontent.com/frappe/frappe_docker/${ERP_BRANCH}/env-production-example" -o "${env_path}"
    fi
  fi

  set_env_var "COMPOSE_PROJECT_NAME" "${PROJECT_NAME}" "${env_path}"
  set_env_var "ERPNEXT_SITE" "${ERP_SITE}" "${env_path}"
  set_env_var "SITES" "${ERP_SITE}" "${env_path}"
  set_env_var "ADMIN_PASSWORD" "${ADMIN_PASSWORD}" "${env_path}"
  set_env_var "MYSQL_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}" "${env_path}"
  set_env_var "MARIADB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}" "${env_path}"
  set_env_var "DB_ROOT_PASSWORD" "${DB_ROOT_PASSWORD}" "${env_path}"
  set_env_var "DB_PASSWORD" "${DB_PASSWORD}" "${env_path}"
  if [[ -n ${LETSENCRYPT_EMAIL} ]]; then
    set_env_var "LETSENCRYPT_EMAIL" "${LETSENCRYPT_EMAIL}" "${env_path}"
  fi

  chmod 640 "${env_path}"
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${env_path}"
}

write_override_file() {
  local override_path="${PROJECT_ROOT}/frappe_docker/docker-compose.override.yml"
  if [[ -f "${override_path}" ]]; then
    log "docker-compose.override.yml existiert bereits – keine Änderungen."
    return
  fi

  log "Schreibe ${override_path}..."
  cat <<EOF >"${override_path}"
# Interner ERPNext-Nginx wird auf localhost gebunden, damit ein externer Proxy genutzt werden kann.
services:
  frontend:
    ports:
      - "127.0.0.1:8080:8080"
  backend:
    environment:
      FRAPPE_SITE_NAME_HEADER: ${ERP_SITE}
EOF
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${override_path}"
}

print_next_steps() {
  cat <<EOF

[INFO] Basis-Setup abgeschlossen.

Nächste Schritte:
 1. Prüfe ${PROJECT_ROOT}/frappe_docker/.env (Passwörter, Mail, Ports) und passe sie bei Bedarf an.
 2. Starte den Stack:
      cd ${PROJECT_ROOT}/frappe_docker
      docker compose --profile production pull
      docker compose --profile production up -d
 3. Erzeuge die ERPNext-Site:
      docker compose exec backend bench new-site ${ERP_SITE} \\
         --admin-password "${ADMIN_PASSWORD}" --db-password "${DB_PASSWORD}"
      docker compose exec backend bench install-app erpnext
 4. Konfiguriere deinen externen Nginx als Reverse Proxy auf http://127.0.0.1:8080.
 5. Melde dich erneut an, falls der Benutzer ${SUDO_USER:-root} gerade der docker-Gruppe hinzugefügt wurde.

Hinweis: Standard-Passwörter sind auf "master999" gesetzt – für produktive Umgebungen unbedingt ändern.
EOF
}

main() {
  require_root
  parse_args "$@"
  check_platform
  ensure_packages
  remove_conflicting_docker_repos
  setup_docker_repo
  install_docker
  prepare_project_root
  clone_frappe_repo
  seed_env_file
  write_override_file
  print_next_steps
}

main "$@"
