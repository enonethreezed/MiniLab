#!/usr/bin/env bash
# Wazuh all-in-one (manager + indexer + dashboard) on Debian Trixie - SIEM
# alternative to ELK/Splunk (ENABLE_WAZUH=1). Mutually exclusive with
# elk-provision.sh/splunk-provision.sh - only one of the three ever runs.
set -euo pipefail

SIEM_IP="${1:-192.168.56.10}"

WAZUH_VER="4.14"
INSTALL_URL="https://packages.wazuh.com/${WAZUH_VER}/wazuh-install.sh"
WORK_DIR="/root/wazuh-install"

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/wazuh-provision.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [WAZUH] $*"; }
ok()  { echo "[$(ts)] [OK]    $*"; }
err() { echo "[$(ts)] [ERR]   $*"; }

log "==========================================================="
log "  Wazuh all-in-one provisioning started"
log "  Log: ${LOG_FILE} (synced to Vagrant host)"
log "==========================================================="

log "Installing prerequisites..."
apt-get update -y -q
apt-get install -y -q curl
ok "Prerequisites installed"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ── 1. Install (skipped if already installed - the official installer isn't
#      safely re-runnable on top of an existing deployment) ────────────────
if [ ! -x /var/ossec/bin/wazuh-control ]; then
  log "Downloading wazuh-install.sh ${WAZUH_VER}..."
  curl -sO "$INSTALL_URL"
  ok "Downloaded wazuh-install.sh"

  log "Running all-in-one install (manager + indexer + dashboard) - this takes a while..."
  bash ./wazuh-install.sh -a
  ok "Wazuh all-in-one install completed"
else
  ok "Wazuh already installed - skipping install (re-provision)"
fi

# ── 2. Extract the installer-generated passwords ────────────────────────────
TAR_FILE="${WORK_DIR}/wazuh-install-files.tar"
if [ ! -f "$TAR_FILE" ]; then
  err "wazuh-install-files.tar not found at ${TAR_FILE} - cannot extract passwords"
  exit 1
fi

tar -xf "$TAR_FILE" -C "$WORK_DIR" wazuh-install-files/wazuh-passwords.txt
PW_FILE="${WORK_DIR}/wazuh-install-files/wazuh-passwords.txt"

get_pw() {
  # $1 = field prefix (indexer|api), $2 = exact username
  grep -A1 "^\s*${1}_username: '${2}'\$" "$PW_FILE" | grep "${1}_password" | sed -E "s/.*: '(.*)'/\1/"
}

DASHBOARD_PASS=$(get_pw indexer admin)
API_PASS=$(get_pw api wazuh)

if [ -z "$DASHBOARD_PASS" ] || [ -z "$API_PASS" ]; then
  err "Could not extract passwords from ${PW_FILE}"
  exit 1
fi
ok "Passwords extracted"

# ── 3. Registration password for agent enrollment ───────────────────────────
# Set our own deterministic password for authd rather than depend on parsing
# a "Random password" line out of ossec.log - same reasoning as this lab's
# other SIEM scripts generating their own credentials rather than recovering
# ones the underlying product chose internally.
REG_PASS="Wz$(openssl rand -hex 9)9!"
echo -n "$REG_PASS" > /var/ossec/etc/authd.pass
chmod 640 /var/ossec/etc/authd.pass
chown root:wazuh /var/ossec/etc/authd.pass

# wazuh-install.sh -a ships ossec.conf with <use_password>no</use_password> -
# password-based enrollment disabled by default, so authd.pass above is
# silently ignored and every agent gets "Invalid request for new agent"
# rejected. Enable it.
sed -i 's|<use_password>no</use_password>|<use_password>yes</use_password>|' \
  /var/ossec/etc/ossec.conf

systemctl restart wazuh-manager
ok "Agent registration password set"

echo "$REG_PASS" > "${LOG_DIR}/wazuh-registration-password.txt"
ok "Registration password saved to logs/wazuh-registration-password.txt"

# ── 4. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
  ufw allow 443/tcp   comment "Wazuh dashboard"        > /dev/null 2>&1 || true
  ufw allow 55000/tcp comment "Wazuh manager API"      > /dev/null 2>&1 || true
  ufw allow 1514/tcp  comment "Wazuh agent data"       > /dev/null 2>&1 || true
  ufw allow 1515/tcp  comment "Wazuh agent enrollment" > /dev/null 2>&1 || true
fi

# ── 5. Credentials + summary ─────────────────────────────────────────────────
{
  echo "# Wazuh Lab Credentials - generated $(date)"
  echo "Dashboard   : https://localhost:4430  (or https://${SIEM_IP})"
  echo "Username    : admin"
  echo "Password    : ${DASHBOARD_PASS}"
  echo ""
  echo "Manager API : https://localhost:55000  (or https://${SIEM_IP}:55000)"
  echo "API user    : wazuh"
  echo "API password: ${API_PASS}"
  echo ""
  echo "Agent enrollment: ${SIEM_IP}:1515 (registration password in logs/wazuh-registration-password.txt)"
} > "${LOG_DIR}/wazuh-credentials.txt"
ok "Credentials saved to logs/wazuh-credentials.txt"

log "==========================================================="
log "  Wazuh all-in-one READY"
log "  Dashboard   : https://localhost:4430"
log "  Manager API : https://localhost:55000"
log "  Credentials : logs/wazuh-credentials.txt"
log "  Full log    : logs/wazuh-provision.log"
log "==========================================================="
