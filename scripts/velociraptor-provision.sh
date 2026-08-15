#!/usr/bin/env bash
# Velociraptor server (live triage / VQL hunting console) on siem - optional,
# additive alongside whichever SIEM stack is running (ENABLE_VELOCIRAPTOR=true).
# Not mutually exclusive with ENABLE_SPLUNK/ENABLE_WAZUH: Velociraptor is a
# hunting/triage tool, not a log-analysis SIEM.
set -euo pipefail

SIEM_IP="${1:-192.168.56.10}"

VELOCIRAPTOR_VER="0.77.2"
DOWNLOAD_URL="https://github.com/Velocidex/velociraptor/releases/download/v${VELOCIRAPTOR_VER}/velociraptor-v${VELOCIRAPTOR_VER}-linux-amd64"
WINDOWS_MSI_URL="https://github.com/Velocidex/velociraptor/releases/download/v${VELOCIRAPTOR_VER}/velociraptor-v${VELOCIRAPTOR_VER}-windows-amd64.msi"
WORK_DIR="/root/velociraptor-install"
CONFIG_DIR="/etc/velociraptor"
CONFIG_FILE="${CONFIG_DIR}/server.config.yaml"

# Frontend (client<->server comms): not the 8000 default - clashes with
# Splunk Web (ENABLE_SPLUNK=1) on the same VM. GUI keeps its 8889 default.
FRONTEND_PORT=8001
GUI_PORT=8889

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/velociraptor-provision.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [VELOCIRAPTOR] $*"; }
ok()  { echo "[$(ts)] [OK]    $*"; }
err() { echo "[$(ts)] [ERR]   $*"; }

log "==========================================================="
log "  Velociraptor provisioning started"
log "  Log: ${LOG_FILE} (synced to Vagrant host)"
log "==========================================================="

# Re-provision guard: Velociraptor stores only a password hash, so an
# existing admin password can't be recovered/re-displayed - do the whole
# install+user-creation exactly once, not partially replay it.
if systemctl is-active --quiet velociraptor_server 2>/dev/null; then
  ok "Velociraptor already installed and running - skipping (re-provision)."
  ok "Original credentials unchanged: logs/velociraptor-credentials.txt"
  exit 0
fi

log "Installing prerequisites..."
apt-get update -y -q
apt-get install -y -q curl python3-yaml
ok "Prerequisites installed"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ── 1. Download ──────────────────────────────────────────────────────────────
log "Downloading Velociraptor ${VELOCIRAPTOR_VER}..."
curl -sL -o velociraptor "$DOWNLOAD_URL"
chmod +x velociraptor
ok "Downloaded Velociraptor binary"

# ── 2. Generate server config, then patch ports/hostname ────────────────────
mkdir -p "$CONFIG_DIR"
log "Generating server config..."
./velociraptor config generate > "$CONFIG_FILE"
ok "Base config generated"

# Proper YAML edit (not sed) - the file also carries embedded PEM keys we
# don't want to risk mangling with a text-level substitution.
python3 - "$CONFIG_FILE" "$SIEM_IP" "$FRONTEND_PORT" "$GUI_PORT" <<'PYEOF'
import sys, yaml

config_file, siem_ip, frontend_port, gui_port = sys.argv[1:5]
frontend_port, gui_port = int(frontend_port), int(gui_port)

with open(config_file) as f:
    cfg = yaml.safe_load(f)

cfg["Frontend"]["hostname"] = siem_ip
cfg["Frontend"]["bind_address"] = "0.0.0.0"
cfg["Frontend"]["bind_port"] = frontend_port
cfg["GUI"]["bind_address"] = "0.0.0.0"
cfg["GUI"]["bind_port"] = gui_port
cfg["Client"]["server_urls"] = [f"https://{siem_ip}:{frontend_port}/"]

with open(config_file, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False)
PYEOF

if ! grep -q "bind_port: ${FRONTEND_PORT}" "$CONFIG_FILE" || \
   ! grep -q "bind_port: ${GUI_PORT}" "$CONFIG_FILE"; then
  err "Config patch didn't apply as expected - check ${CONFIG_FILE} manually"
  exit 1
fi
chmod 600 "$CONFIG_FILE"
ok "Config patched: frontend ${SIEM_IP}:${FRONTEND_PORT}, GUI 0.0.0.0:${GUI_PORT}"

# ── 3. Package + install as a systemd service ────────────────────────────────
log "Building and installing the server .deb package..."
./velociraptor debian server --config "$CONFIG_FILE"
dpkg -i velociraptor_server_*_amd64.deb
ok "Velociraptor server installed as a systemd service (velociraptor_server)"

# ── 4. Admin user ─────────────────────────────────────────────────────────────
ADMIN_PASS="Vr$(openssl rand -hex 9)9!"
velociraptor --config "$CONFIG_FILE" user add --role=administrator admin "$ADMIN_PASS"
systemctl restart velociraptor_server
ok "Admin user created, service restarted to pick it up"

# ── 5. Firewall ────────────────────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
  ufw allow "${FRONTEND_PORT}/tcp" comment "Velociraptor client-server frontend" > /dev/null 2>&1 || true
  ufw allow "${GUI_PORT}/tcp"      comment "Velociraptor GUI"                   > /dev/null 2>&1 || true
fi

# ── 6. Credentials + client config for the Windows agent scripts ────────────
{
  echo "# Velociraptor Lab Credentials - generated $(date)"
  echo "GUI      : https://localhost:${GUI_PORT}  (or https://${SIEM_IP}:${GUI_PORT})"
  echo "Username : admin"
  echo "Password : ${ADMIN_PASS}"
  echo ""
  echo "Client config: logs/velociraptor-client.config.yaml (server URL + CA baked"
  echo "in - no separate enrollment token needed)"
} > "${LOG_DIR}/velociraptor-credentials.txt"
ok "Credentials saved to logs/velociraptor-credentials.txt"

velociraptor --config "$CONFIG_FILE" config client > "${LOG_DIR}/velociraptor-client.config.yaml"
chmod 644 "${LOG_DIR}/velociraptor-client.config.yaml"
ok "Client config saved to logs/velociraptor-client.config.yaml"

# ── 7. Windows client installer, pre-configured (official repack path) ──────
# The Linux binary can repack a Windows MSI just fine - it's only rewriting
# an embedded config resource, not doing anything OS-specific. This gives
# the Windows agent scripts a single ready-to-run installer, same shape as
# the fleet-enrollment-token.txt handoff from elk-provision.sh.
log "Downloading Velociraptor Windows client MSI..."
curl -sL -o velociraptor-windows-amd64.msi "$WINDOWS_MSI_URL"
ok "Downloaded Windows MSI template"

log "Repacking client config into the Windows MSI..."
./velociraptor config repack --msi velociraptor-windows-amd64.msi \
  "${LOG_DIR}/velociraptor-client.config.yaml" \
  "${LOG_DIR}/velociraptor-client.msi"
chmod 644 "${LOG_DIR}/velociraptor-client.msi"
ok "Pre-configured client installer saved to logs/velociraptor-client.msi"

log "==========================================================="
log "  Velociraptor READY"
log "  GUI         : https://localhost:${GUI_PORT}"
log "  Credentials : logs/velociraptor-credentials.txt"
log "  Client MSI  : logs/velociraptor-client.msi (pre-configured, ready to install)"
log "  Full log    : logs/velociraptor-provision.log"
log "==========================================================="
