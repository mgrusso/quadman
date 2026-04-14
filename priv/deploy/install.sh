#!/usr/bin/env bash
# Quadman install script — idempotent, run as root.
# Supports: RHEL/CentOS 8+, Fedora, Debian, Ubuntu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yourorg/quadman/main/priv/deploy/install.sh | bash
#   # or: bash install.sh [--caddy] [--user quadman] [--dir /opt/quadman]
#
# What it does:
#   1. Creates a dedicated 'quadman' system user
#   2. Creates /opt/quadman, /var/lib/quadman, /etc/quadman
#   3. Installs Caddy from official repos (optional, --caddy flag)
#   4. Enables linger for the quadman user (persistent user systemd session)
#   5. Installs the Quadman systemd unit
#   6. Prints next steps

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
QUADMAN_USER="${QUADMAN_USER:-quadman}"
INSTALL_DIR="${INSTALL_DIR:-/opt/quadman}"
DATA_DIR="${DATA_DIR:-/var/lib/quadman}"
CONFIG_DIR="${CONFIG_DIR:-/etc/quadman}"
INSTALL_CADDY=false

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caddy) INSTALL_CADDY=true ;;
    --user) QUADMAN_USER="$2"; shift ;;
    --dir) INSTALL_DIR="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Detect distro
# ---------------------------------------------------------------------------
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID}"
  else
    echo "unknown"
  fi
}

DISTRO="$(detect_distro)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  [+] $*"; }
warn()  { echo "  [!] $*" >&2; }
die()   { echo "  [✗] $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."
}

# ---------------------------------------------------------------------------
# Caddy installation
# ---------------------------------------------------------------------------
install_caddy_rhel() {
  info "Installing Caddy (RHEL/CentOS/Fedora)..."
  if command -v dnf &>/dev/null; then
    dnf install -y 'dnf-command(copr)' 2>/dev/null || true
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy
  else
    die "dnf not found — cannot install Caddy on this system."
  fi
}

install_caddy_debian() {
  info "Installing Caddy (Debian/Ubuntu)..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y caddy
}

install_caddy() {
  if command -v caddy &>/dev/null; then
    info "Caddy already installed ($(caddy version))."
    return
  fi

  case "$DISTRO" in
    rhel|centos|almalinux|rocky|fedora) install_caddy_rhel ;;
    debian|ubuntu|linuxmint|pop)        install_caddy_debian ;;
    *)
      warn "Unknown distro '${DISTRO}'. Attempting Debian-style install..."
      install_caddy_debian
      ;;
  esac

  systemctl enable caddy
  info "Caddy installed and enabled."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root

echo ""
echo "Quadman installer"
echo "─────────────────────────────────────────"
info "User:       ${QUADMAN_USER}"
info "Install:    ${INSTALL_DIR}"
info "Data:       ${DATA_DIR}"
info "Config:     ${CONFIG_DIR}"
info "Caddy:      ${INSTALL_CADDY}"
echo ""

# 1. System user
if ! id "${QUADMAN_USER}" &>/dev/null; then
  info "Creating system user '${QUADMAN_USER}'..."
  useradd \
    --system \
    --shell /sbin/nologin \
    --home-dir "${INSTALL_DIR}" \
    --create-home \
    "${QUADMAN_USER}"
else
  info "User '${QUADMAN_USER}' already exists."
fi

# 2. Directories
info "Creating directories..."
install -d -m 755 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${INSTALL_DIR}"
install -d -m 750 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${DATA_DIR}"
install -d -m 750 -o root             -g "${QUADMAN_USER}" "${CONFIG_DIR}"

# Quadlet dirs (owned by quadman user)
QUADMAN_HOME="$(getent passwd "${QUADMAN_USER}" | cut -d: -f6)"
install -d -m 700 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" \
  "${QUADMAN_HOME}/.config/containers/systemd" \
  "${QUADMAN_HOME}/.config/quadman/secrets"

# 3. env file (don't overwrite existing)
if [[ ! -f "${CONFIG_DIR}/env" ]]; then
  info "Creating ${CONFIG_DIR}/env from template..."
  cat > "${CONFIG_DIR}/env" <<EOF
# Quadman runtime environment — edit and then: systemctl restart quadman
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
DATABASE_PATH=${DATA_DIR}/quadman.db
PHX_HOST=quadman.example.com
PORT=4000
# CADDY_ENABLED=true
# CADDY_ADMIN_URL=http://localhost:2019
EOF
  chmod 600 "${CONFIG_DIR}/env"
  chown "${QUADMAN_USER}:${QUADMAN_USER}" "${CONFIG_DIR}/env"
  warn "Generated SECRET_KEY_BASE in ${CONFIG_DIR}/env — review and update PHX_HOST before starting."
else
  info "${CONFIG_DIR}/env already exists, skipping."
fi

# 4. loginctl enable-linger (keeps user systemd session alive without a login)
info "Enabling linger for '${QUADMAN_USER}'..."
loginctl enable-linger "${QUADMAN_USER}"

# 5. XDG_RUNTIME_DIR for the unit
QUADMAN_UID="$(id -u "${QUADMAN_USER}")"

# 6. Install systemd service unit
info "Installing quadman.service..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="${SCRIPT_DIR}/quadman.service"

if [[ -f "${SERVICE_SRC}" ]]; then
  sed "s|REPLACE_WITH_UID|${QUADMAN_UID}|g" "${SERVICE_SRC}" \
    > /etc/systemd/system/quadman.service
else
  warn "quadman.service template not found at ${SERVICE_SRC}."
  warn "Download and install it manually from the Quadman release."
fi

systemctl daemon-reload

# 7. Caddy (optional)
if [[ "${INSTALL_CADDY}" == "true" ]]; then
  install_caddy

  CADDY_DIR="/etc/caddy"
  if [[ ! -f "${CADDY_DIR}/Caddyfile" ]]; then
    info "Installing example Caddyfile..."
    cp "${SCRIPT_DIR}/Caddyfile.example" "${CADDY_DIR}/Caddyfile"
    warn "Edit ${CADDY_DIR}/Caddyfile and replace 'quadman.example.com' with your hostname."
    warn "Then: systemctl enable --now caddy"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────────"
echo "Installation complete. Next steps:"
echo ""
echo "  1. Extract the Quadman release to ${INSTALL_DIR}/"
echo "     tar -xzf quadman-*.tar.gz -C ${INSTALL_DIR}/"
echo ""
echo "  2. Edit ${CONFIG_DIR}/env:"
echo "     - Set PHX_HOST to your domain"
echo "     - Review SECRET_KEY_BASE (auto-generated)"
if [[ "${INSTALL_CADDY}" == "true" ]]; then
echo "     - Set CADDY_ENABLED=true"
fi
echo ""
echo "  3. Run migrations:"
echo "     sudo -u ${QUADMAN_USER} ${INSTALL_DIR}/bin/quadman eval \"Quadman.Release.migrate()\""
echo ""
echo "  4. Start Quadman:"
echo "     systemctl enable --now quadman"
echo ""
if [[ "${INSTALL_CADDY}" == "true" ]]; then
echo "  5. Configure Caddy:"
echo "     Edit /etc/caddy/Caddyfile, set your hostname, then:"
echo "     systemctl enable --now caddy"
echo ""
fi
