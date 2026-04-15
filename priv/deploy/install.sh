#!/usr/bin/env bash
# Quadman install script — idempotent, run as root.
# Supports: RHEL/CentOS 8+, Fedora, Debian, Ubuntu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | bash
#   # or: bash install.sh [--user quadman] [--dir /opt/quadman]
#
# What it does:
#   1. Creates a dedicated 'quadman' system user
#   2. Creates /opt/quadman, /var/lib/quadman, /etc/quadman
#   3. Sets net.ipv4.ip_unprivileged_port_start=80 so rootless Podman
#      containers can bind ports 80 and 443 (required for Caddy)
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

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) QUADMAN_USER="$2"; shift ;;
    --dir) INSTALL_DIR="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

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
# Main
# ---------------------------------------------------------------------------
require_root

echo ""
echo "Quadman installer"
echo "─────────────────────────────────────────"
info "User:    ${QUADMAN_USER}"
info "Install: ${INSTALL_DIR}"
info "Data:    ${DATA_DIR}"
info "Config:  ${CONFIG_DIR}"
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

# Caddy data dir (owned by quadman user, written by Quadman at deploy time)
install -d -m 750 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${DATA_DIR}/caddy"

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
EOF
  chmod 600 "${CONFIG_DIR}/env"
  chown "${QUADMAN_USER}:${QUADMAN_USER}" "${CONFIG_DIR}/env"
  warn "Generated SECRET_KEY_BASE in ${CONFIG_DIR}/env — update PHX_HOST before starting."
else
  info "${CONFIG_DIR}/env already exists, skipping."
fi

# 4. sysctl: allow rootless containers to bind ports 80 and 443
# Required for the Caddy container deployed via the Quadman UI.
SYSCTL_CONF="/etc/sysctl.d/99-quadman.conf"
if [[ ! -f "${SYSCTL_CONF}" ]]; then
  info "Setting net.ipv4.ip_unprivileged_port_start=80..."
  echo "net.ipv4.ip_unprivileged_port_start=80" > "${SYSCTL_CONF}"
  sysctl -p "${SYSCTL_CONF}" >/dev/null
else
  info "sysctl config already exists at ${SYSCTL_CONF}, skipping."
fi

# 5. loginctl enable-linger (keeps user systemd session alive without a login)
info "Enabling linger for '${QUADMAN_USER}'..."
loginctl enable-linger "${QUADMAN_USER}"

# 6. XDG_RUNTIME_DIR for the unit
QUADMAN_UID="$(id -u "${QUADMAN_USER}")"

# 7. Install systemd service unit
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
echo ""
echo "  3. Start Quadman (migrations run automatically on first boot):"
echo "     systemctl enable --now quadman"
echo ""
echo "  4. Open the Quadman UI, log in, and go to Settings → Caddy"
echo "     to deploy the Caddy container for automatic HTTPS routing."
echo ""
