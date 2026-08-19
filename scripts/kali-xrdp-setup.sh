#!/usr/bin/env bash
# xrdp on kali - lets you RDP into the box's existing XFCE desktop instead of
# relying on VirtualBox's own guest-display integration, whose dynamic
# resize is unreliable on a headless-by-default VM. FreeRDP-based clients
# (xfreerdp /dynamic-resolution, Remmina, ...) negotiate resize properly.
set -euo pipefail

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/kali-xrdp-setup.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [XRDP] $*"; }
ok()  { echo "[$(ts)] [OK]   $*"; }

log "=========================================================="
log "  Kali xrdp setup started"
log "=========================================================="

log "Installing xrdp..."
apt-get update -y -q
apt-get install -y -q xrdp
ok "Package installed"

# Debian/Kali's xrdp package doesn't put the xrdp user in the ssl-cert
# group, so it can't read the snakeoil TLS key /etc/xrdp/key.pem is
# symlinked to. Without this, xrdp silently falls back to legacy "classic"
# RDP security, which most modern clients (FreeRDP/Remmina) fail to
# complete a handshake with ("MAC checksum error for non-FIPS PDU").
log "Adding xrdp user to ssl-cert group (needed to read the TLS key)..."
usermod -aG ssl-cert xrdp
ok "xrdp added to ssl-cert"

log "Enabling and starting xrdp..."
systemctl enable --now xrdp xrdp-sesman
# Restart rather than just enable --now, in case this is a re-provision run
# and xrdp was already active before the group change above - group
# membership is only picked up when the daemon process restarts.
systemctl restart xrdp

ok "xrdp listening on port 3389"
log "Note: xfce4-session allows only one session per user. RDP in as"
log "'vagrant' will fail to start a desktop if a console session for"
log "'vagrant' is already open (e.g. the VirtualBox GUI window) - use one"
log "access method at a time, not both."

log "=========================================================="
log "  Kali xrdp setup COMPLETED"
log "  RDP: 192.168.56.100:3389 (vagrant/vagrant)"
log "=========================================================="
