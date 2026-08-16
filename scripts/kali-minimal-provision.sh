#!/usr/bin/env bash
# Strips kalilinux/rolling down to a minimal footprint (ENABLE_KALI_MINIMAL=true).
# No smaller official Kali Vagrant box exists - the box download itself stays
# the same size. This trims the desktop environment and the
# kali-linux-default tool metapackage the box ships with, post-boot, since
# this VM runs headless (vb.gui = false) and doesn't need either - only
# kali-linux-core (base system) is left installed.
set -euo pipefail

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/kali-minimal-provision.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [KALI-MIN] $*"; }
ok()  { echo "[$(ts)] [OK]       $*"; }

log "==========================================================="
log "  Kali minimal strip-down started"
log "==========================================================="

export DEBIAN_FRONTEND=noninteractive

log "Purging desktop environment and default tool metapackage..."
apt-get purge -y kali-linux-default 'kali-desktop-*' 'xfce4*' 'lightdm*' 2>&1 | tail -5 || true
ok "Metapackages purged (packages not present are skipped, not an error)"

log "Autoremoving now-orphaned dependencies..."
apt-get autoremove --purge -y
apt-get clean
ok "Autoremove + clean complete"

log "Confirming kali-linux-core is still present..."
if dpkg -s kali-linux-core &> /dev/null; then
  ok "kali-linux-core present"
else
  log "kali-linux-core missing - reinstalling"
  apt-get install -y kali-linux-core
  ok "kali-linux-core reinstalled"
fi

log "==========================================================="
log "  Kali minimal strip-down complete"
log "  Disk usage: $(df -h / | awk 'NR==2 {print $3 " used / " $2 " total"}')"
log "==========================================================="
