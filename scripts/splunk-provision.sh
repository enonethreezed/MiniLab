#!/usr/bin/env bash
# Splunk Enterprise on Debian Trixie - SIEM alternative to ELK (ENABLE_SPLUNK=1)
# Mutually exclusive with elk-provision.sh - only one of the two ever runs.
set -euo pipefail

SIEM_IP="${1:-192.168.56.10}"

SPLUNK_HOME="/opt/splunk"
SPLUNK_VER="10.4.1"
SPLUNK_BUILD="5a009d941268"
SPLUNK_DEB="splunk-${SPLUNK_VER}-${SPLUNK_BUILD}-linux-amd64.deb"
SPLUNK_URL="https://download.splunk.com/products/splunk/releases/${SPLUNK_VER}/linux/${SPLUNK_DEB}"

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/splunk-provision.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [SPLUNK] $*"; }
ok()  { echo "[$(ts)] [OK]     $*"; }
err() { echo "[$(ts)] [ERR]    $*"; }

log "==========================================================="
log "  Splunk Enterprise provisioning started"
log "  Log: ${LOG_FILE} (synced to Vagrant host)"
log "==========================================================="

# License is optional: if it's missing or expired, Splunk still installs
# fine and runs in Free/Trial mode (single indexer, no auth roles, no
# alerting/distributed search, 500MB/day after the 60-day Enterprise Trial
# window) - limited, but a valid way to stand up the lab while a real
# license is pending. Never block provisioning on this.
LICENSE_SRC="/tmp/Splunk.License"
LICENSE_VALID=false
if [ -f "$LICENSE_SRC" ]; then
  LICENSE_EXPIRATION=$(grep -oP '(?<=<expiration_time>)\d+(?=</expiration_time>)' "$LICENSE_SRC" || true)
  NOW_EPOCH=$(date +%s)
  if [ -z "$LICENSE_EXPIRATION" ]; then
    log "Could not find <expiration_time> in ${LICENSE_SRC} - continuing in Splunk Free/Trial mode"
  elif [ "$LICENSE_EXPIRATION" -le "$NOW_EPOCH" ]; then
    log "License expired on $(date -d "@${LICENSE_EXPIRATION}" '+%Y-%m-%d %H:%M:%S %Z') - continuing in Splunk Free/Trial mode"
  else
    LICENSE_VALID=true
    ok "License valid until $(date -d "@${LICENSE_EXPIRATION}" '+%Y-%m-%d %H:%M:%S %Z')"
  fi
else
  log "No license file at ${LICENSE_SRC} - continuing in Splunk Free/Trial mode"
fi

# ── 1. Prerequisites + download + install package ──────────────────────────
log "Installing prerequisites..."
apt-get update -y -q
apt-get install -y -q curl
ok "Prerequisites installed"

log "Downloading Splunk Enterprise ${SPLUNK_VER}..."
wget -q -O "/tmp/${SPLUNK_DEB}" "$SPLUNK_URL"
ok "Downloaded ${SPLUNK_DEB}"

log "Installing Splunk Enterprise..."
apt-get install -y -q "/tmp/${SPLUNK_DEB}"
rm -f "/tmp/${SPLUNK_DEB}"
ok "Splunk Enterprise installed to ${SPLUNK_HOME}"

# ── 2. First start: accept license, (re)seed admin password ────────────────
# Idempotent the same way elk-provision.sh's elastic user is: every
# provisioning run resets to a fresh generated admin password rather than
# trying to recover a prior one.
ADMIN_PASS="Sp$(openssl rand -hex 9)9!"

log "Configuring admin password..."
if pgrep -f "[s]plunkd" > /dev/null 2>&1; then
  "${SPLUNK_HOME}/bin/splunk" stop --run-as-root
fi
rm -f "${SPLUNK_HOME}/etc/passwd"

"${SPLUNK_HOME}/bin/splunk" start --accept-license --answer-yes --no-prompt \
  --seed-passwd "$ADMIN_PASS" --run-as-root
ok "Splunk started, admin password (re)seeded"

AUTH="admin:${ADMIN_PASS}"

wait_for_splunkd() {
  log "Waiting for splunkd management port (8089)..."
  for i in $(seq 1 30); do
    if curl -sk "https://localhost:8089/services/server/info" -u "$AUTH" -o /dev/null; then
      ok "splunkd is up"
      return 0
    fi
    log "  attempt $i/30 - waiting 10s..."
    sleep 10
  done
  err "splunkd never became reachable on 8089"
  exit 1
}
wait_for_splunkd

# ── 3. Apply license (skipped if missing/expired - Free/Trial mode) ────────
if [ "$LICENSE_VALID" = true ]; then
  log "Applying license from ${LICENSE_SRC}..."
  "${SPLUNK_HOME}/bin/splunk" add licenses "$LICENSE_SRC" -auth "$AUTH"
  "${SPLUNK_HOME}/bin/splunk" restart --run-as-root
  wait_for_splunkd
  ok "License applied"
else
  log "Skipping license application - running in Splunk Free/Trial mode"
fi

# ── 4. Enable receiving from forwarders ─────────────────────────────────────
log "Enabling receiving on 9997 for forwarders..."
"${SPLUNK_HOME}/bin/splunk" enable listen 9997 -auth "$AUTH"
ok "Receiving enabled on 9997"

# ── 5. Boot-start (systemd) ─────────────────────────────────────────────────
log "Enabling boot-start..."
"${SPLUNK_HOME}/bin/splunk" enable boot-start --accept-license --answer-yes --no-prompt --run-as-root
ok "Boot-start enabled"

# ── 6. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
  ufw allow 8000/tcp comment "Splunk Web"          > /dev/null 2>&1 || true
  ufw allow 8089/tcp comment "Splunk mgmt"         > /dev/null 2>&1 || true
  ufw allow 9997/tcp comment "Splunk forwarder-in" > /dev/null 2>&1 || true
fi

# ── 7. Credentials + summary ─────────────────────────────────────────────────
if [ "$LICENSE_VALID" = true ]; then LICENSE_MODE="Enterprise (licensed)"; else LICENSE_MODE="Free/Trial (no valid license applied)"; fi

{
  echo "# Splunk Lab Credentials - generated $(date)"
  echo "Splunk Web : http://localhost:8000  (or http://${SIEM_IP}:8000)"
  echo "Username   : admin"
  echo "Password   : ${ADMIN_PASS}"
  echo ""
  echo "License    : ${LICENSE_MODE}"
  echo "Receiving  : ${SIEM_IP}:9997 (for Universal Forwarders)"
} > "${LOG_DIR}/splunk-credentials.txt"
ok "Credentials saved to logs/splunk-credentials.txt"

log "==========================================================="
log "  Splunk Enterprise READY"
log "  License     : ${LICENSE_MODE}"
log "  Splunk Web  : http://localhost:8000"
log "  Receiving   : ${SIEM_IP}:9997"
log "  Credentials : logs/splunk-credentials.txt"
log "  Full log    : logs/splunk-provision.log"
log "==========================================================="
