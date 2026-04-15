#!/usr/bin/env bash
# Quadman install script — idempotent, run as root.
# Supports: RHEL/CentOS 8+, Fedora, Debian, Ubuntu
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | bash
#   # or: bash install.sh [--user quadman] [--dir /opt/quadman]
#
# What it does:
#   1. Installs Podman (required)
#   2. Creates a dedicated 'quadman' system user
#   3. Creates /opt/quadman, /var/lib/quadman, /etc/quadman
#   4. Enables the Podman REST socket for the quadman user
#   5. Sets net.ipv4.ip_unprivileged_port_start=80 (required for Caddy on ports 80/443)
#   6. Enables linger for the quadman user
#   7. Installs the Quadman systemd unit

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
    --dir)  INSTALL_DIR="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "  [+] $*"; }
warn() { echo "  [!] $*" >&2; }
die()  { echo "  [✗] $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID}"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# 1. Install Podman
# ---------------------------------------------------------------------------
install_podman() {
  if command -v podman &>/dev/null; then
    info "Podman already installed ($(podman --version))."
    return
  fi

  local distro
  distro="$(detect_distro)"
  info "Installing Podman (distro: ${distro})..."

  case "$distro" in
    rhel|centos|almalinux|rocky|fedora)
      dnf install -y podman ;;
    debian|ubuntu|linuxmint|pop)
      apt-get update -q
      apt-get install -y podman ;;
    *)
      warn "Unknown distro '${distro}'. Attempting Debian-style install..."
      apt-get update -q
      apt-get install -y podman ;;
  esac

  info "Podman installed: $(podman --version)"
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

# 1. Podman (required — Quadman cannot function without it)
install_podman

# 2. System user
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

QUADMAN_UID="$(id -u "${QUADMAN_USER}")"
QUADMAN_HOME="$(getent passwd "${QUADMAN_USER}" | cut -d: -f6)"

# 2b. subUID / subGID — required for rootless Podman to map container UIDs
# Without these, images with non-root files (e.g. vaultwarden) fail to pull.
if ! grep -q "^${QUADMAN_USER}:" /etc/subuid 2>/dev/null; then
  info "Adding subUID range for '${QUADMAN_USER}'..."
  echo "${QUADMAN_USER}:100000:65536" >> /etc/subuid
else
  info "subUID already configured for '${QUADMAN_USER}'."
fi
if ! grep -q "^${QUADMAN_USER}:" /etc/subgid 2>/dev/null; then
  info "Adding subGID range for '${QUADMAN_USER}'..."
  echo "${QUADMAN_USER}:100000:65536" >> /etc/subgid
else
  info "subGID already configured for '${QUADMAN_USER}'."
fi

# 2c. systemd-journal group — allows reading the system journal for deploy diagnostics
if getent group systemd-journal &>/dev/null; then
  if ! id -nG "${QUADMAN_USER}" 2>/dev/null | grep -qw systemd-journal; then
    info "Adding '${QUADMAN_USER}' to systemd-journal group..."
    usermod -aG systemd-journal "${QUADMAN_USER}"
  else
    info "'${QUADMAN_USER}' already in systemd-journal group."
  fi
fi

# 3. Directories
info "Creating directories..."
install -d -m 755 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${INSTALL_DIR}"
install -d -m 750 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${DATA_DIR}"
install -d -m 750 -o root             -g "${QUADMAN_USER}" "${CONFIG_DIR}"
install -d -m 750 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" "${DATA_DIR}/caddy"
install -d -m 700 -o "${QUADMAN_USER}" -g "${QUADMAN_USER}" \
  "${QUADMAN_HOME}/.config/containers/systemd" \
  "${QUADMAN_HOME}/.config/quadman/secrets"

# 4. env file (don't overwrite existing)
SOCKET_PATH="/run/user/${QUADMAN_UID}/podman/podman.sock"

if [[ ! -f "${CONFIG_DIR}/env" ]]; then
  info "Creating ${CONFIG_DIR}/env..."
  cat > "${CONFIG_DIR}/env" <<EOF
# Quadman runtime environment — edit and then: systemctl restart quadman
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
DATABASE_PATH=${DATA_DIR}/quadman.db
PHX_HOST=quadman.example.com
PORT=4000
PODMAN_SOCKET_PATH=${SOCKET_PATH}
EOF
  chmod 600 "${CONFIG_DIR}/env"
  chown "${QUADMAN_USER}:${QUADMAN_USER}" "${CONFIG_DIR}/env"
  warn "Update PHX_HOST in ${CONFIG_DIR}/env before starting Quadman."
else
  info "${CONFIG_DIR}/env already exists, skipping."
  # Ensure PODMAN_SOCKET_PATH is present with correct UID (idempotent update)
  if ! grep -q "PODMAN_SOCKET_PATH" "${CONFIG_DIR}/env"; then
    echo "PODMAN_SOCKET_PATH=${SOCKET_PATH}" >> "${CONFIG_DIR}/env"
    info "Added PODMAN_SOCKET_PATH to existing env file."
  fi
fi

# 5. sysctl — allow rootless containers to bind ports 80 and 443 (for Caddy)
SYSCTL_CONF="/etc/sysctl.d/99-quadman.conf"
if [[ ! -f "${SYSCTL_CONF}" ]]; then
  info "Setting net.ipv4.ip_unprivileged_port_start=80..."
  echo "net.ipv4.ip_unprivileged_port_start=80" > "${SYSCTL_CONF}"
  sysctl -p "${SYSCTL_CONF}" >/dev/null
else
  info "sysctl already configured at ${SYSCTL_CONF}, skipping."
fi

# 6. Linger — keeps the user systemd session alive without an interactive login
info "Enabling linger for '${QUADMAN_USER}'..."
loginctl enable-linger "${QUADMAN_USER}"

# Give user session a moment to start if it wasn't already running
sleep 2

# 7. Podman socket — enable and start the REST API socket for the quadman user
info "Enabling Podman socket for '${QUADMAN_USER}'..."
XDG_RUNTIME_DIR="/run/user/${QUADMAN_UID}"

if systemctl --user -M "${QUADMAN_USER}@" enable podman.socket 2>/dev/null; then
  systemctl --user -M "${QUADMAN_USER}@" start podman.socket 2>/dev/null || true
  info "Podman socket enabled and started."
else
  # Fallback for older systemd versions
  sudo -u "${QUADMAN_USER}" \
    XDG_RUNTIME_DIR="/run/user/${QUADMAN_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${QUADMAN_UID}/bus" \
    systemctl --user enable --now podman.socket 2>/dev/null || \
    warn "Could not enable Podman socket automatically. Run as ${QUADMAN_USER}: systemctl --user enable --now podman.socket"
fi

# Verify socket exists
sleep 1
if [[ -S "${SOCKET_PATH}" ]]; then
  info "Podman socket is active at ${SOCKET_PATH}"
else
  warn "Podman socket not yet visible at ${SOCKET_PATH} — it may appear after first login/linger activation."
fi

# 8. Sudoers rule — allows the quadman user to restart its own service
# Required for the one-click update feature in the Settings UI.
SUDOERS_FILE="/etc/sudoers.d/quadman"
if [[ ! -f "${SUDOERS_FILE}" ]]; then
  info "Installing sudoers rule for service restart..."
  SYSTEMCTL_BIN="$(command -v systemctl)"
  echo "${QUADMAN_USER} ALL=(ALL) NOPASSWD: ${SYSTEMCTL_BIN} restart quadman" > "${SUDOERS_FILE}"
  chmod 440 "${SUDOERS_FILE}"
else
  info "Sudoers rule already exists at ${SUDOERS_FILE}, skipping."
fi

# 9. Quadman systemd service unit
info "Installing quadman.service..."
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "bash" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
SERVICE_SRC="${SCRIPT_DIR:+${SCRIPT_DIR}/}quadman.service"
RELEASE_SERVICE="$(find "${INSTALL_DIR}" -name "quadman.service" 2>/dev/null | head -1)"

if [[ -f "${SERVICE_SRC}" ]]; then
  sed "s|REPLACE_WITH_UID|${QUADMAN_UID}|g" "${SERVICE_SRC}" > /etc/systemd/system/quadman.service
elif [[ -n "${RELEASE_SERVICE}" ]]; then
  sed "s|REPLACE_WITH_UID|${QUADMAN_UID}|g" "${RELEASE_SERVICE}" > /etc/systemd/system/quadman.service
  info "Installed quadman.service from release tarball."
else
  warn "quadman.service not found — extract the release first, then re-run this script."
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
echo ""
echo "  3. Start Quadman (migrations run automatically on first boot):"
echo "     systemctl enable --now quadman"
echo ""
echo "  4. Open the Quadman UI → Settings → Caddy to deploy the Caddy container."
echo ""
