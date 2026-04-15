#!/usr/bin/env bash
# Quadman uninstall script — removes everything created by install.sh.
# Run as root (or via sudo).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/uninstall.sh | bash
#   # or: bash uninstall.sh [--user quadman] [--dir /opt/quadman]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (must match what install.sh used)
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

require_root() {
  [[ $EUID -eq 0 ]] || { echo "  [✗] This script must be run as root (or via sudo)." >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_root

echo ""
echo "Quadman uninstaller"
echo "─────────────────────────────────────────"
warn "This will PERMANENTLY remove Quadman and all its data."
warn "User: ${QUADMAN_USER}  |  Install: ${INSTALL_DIR}  |  Data: ${DATA_DIR}"
echo ""
read -r -p "  Type 'yes' to continue: " confirm
[[ "${confirm}" == "yes" ]] || { echo "  Aborted."; exit 0; }
echo ""

# 1. Stop and disable the systemd service
info "Stopping and disabling quadman.service..."
systemctl stop quadman 2>/dev/null && info "Service stopped." || warn "Service was not running."
systemctl disable quadman 2>/dev/null || true

# 2. Stop any user-session Podman socket / containers
if id "${QUADMAN_USER}" &>/dev/null; then
  QUADMAN_UID="$(id -u "${QUADMAN_USER}")"
  info "Stopping user Podman socket for '${QUADMAN_USER}'..."
  systemctl --user -M "${QUADMAN_USER}@" stop podman.socket 2>/dev/null || true
  systemctl --user -M "${QUADMAN_USER}@" disable podman.socket 2>/dev/null || true

  # Stop all Quadlet containers managed by the quadman user
  info "Stopping all user-session container units..."
  systemctl --user -M "${QUADMAN_USER}@" stop '*.service' 2>/dev/null || true

  # Disable linger
  info "Disabling linger for '${QUADMAN_USER}'..."
  loginctl disable-linger "${QUADMAN_USER}" 2>/dev/null || true
fi

# 3. Remove systemd service unit
info "Removing /etc/systemd/system/quadman.service..."
rm -f /etc/systemd/system/quadman.service
systemctl daemon-reload

# 4. Remove sudoers rule
info "Removing sudoers rule..."
rm -f /etc/sudoers.d/quadman

# 5. Remove sysctl config
info "Removing sysctl config..."
rm -f /etc/sysctl.d/99-quadman.conf
# Restore the default unprivileged port (1024) if nothing else has changed it
if ! grep -rq "ip_unprivileged_port_start" /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null; then
  sysctl -w net.ipv4.ip_unprivileged_port_start=1024 >/dev/null 2>&1 || true
fi

# 6. Remove subUID / subGID entries for the quadman user
if grep -q "^${QUADMAN_USER}:" /etc/subuid 2>/dev/null; then
  info "Removing subUID entry for '${QUADMAN_USER}'..."
  sed -i "/^${QUADMAN_USER}:/d" /etc/subuid
fi
if grep -q "^${QUADMAN_USER}:" /etc/subgid 2>/dev/null; then
  info "Removing subGID entry for '${QUADMAN_USER}'..."
  sed -i "/^${QUADMAN_USER}:/d" /etc/subgid
fi

# 7. Remove install, data, and config directories
info "Removing ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}"

info "Removing ${DATA_DIR}..."
rm -rf "${DATA_DIR}"

info "Removing ${CONFIG_DIR}..."
rm -rf "${CONFIG_DIR}"

# 8. Remove system user (also removes home dir if it was set to INSTALL_DIR)
if id "${QUADMAN_USER}" &>/dev/null; then
  info "Removing system user '${QUADMAN_USER}'..."
  userdel "${QUADMAN_USER}" 2>/dev/null || warn "Could not remove user '${QUADMAN_USER}' — remove manually with: userdel ${QUADMAN_USER}"
else
  info "User '${QUADMAN_USER}' does not exist, skipping."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────────"
echo "Quadman has been fully uninstalled."
echo ""
echo "Note: Podman itself was NOT removed. To remove it:"
echo "  apt-get remove --purge podman   # Debian/Ubuntu"
echo "  dnf remove podman               # RHEL/Fedora"
echo ""
