#!/usr/bin/env bash
# Apache Guacamole (guacd + webapp) via Docker Compose on siem
# SOC Blue Team Lab
#
# guacamole-server is not packaged for Debian 12/13 at all (pulled from
# Debian entirely in 2024, never returned) - Docker Compose with the
# official images is the actually-maintained install path, not a fallback.
# Requires scripts/docker-setup.sh to have already run.
set -euo pipefail

WSRV_IP="${1:-192.168.56.20}"
WIN11_IP="${2:-192.168.56.30}"
DOMAIN_NETBIOS="${3:-MINILAB}"
KALI_IP="${4:-192.168.56.100}"

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/guacamole-setup.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [GUAC] $*"; }
ok()  { echo "[$(ts)] [OK]   $*"; }
err() { echo "[$(ts)] [ERR]  $*"; }

log "=========================================================="
log "  Guacamole setup started"
log "=========================================================="

if ! command -v docker &>/dev/null; then
  err "Docker not found - run the 'docker-setup' provisioner first"
  exit 1
fi

GUAC_DIR="/opt/guacamole"
SSH_DIR="${GUAC_DIR}/ssh"
mkdir -p "$SSH_DIR"

# ── SSH keypair for the "siem - SSH" connection ────────────────────────────
# A dedicated key, not Vagrant's own insecure_private_key (that key is the
# literal same public key shipped with every Vagrant box in the world - not
# appropriate as a standing credential for a remote-access gateway).
KEY_PATH="${SSH_DIR}/guac_ed25519"
if [ ! -f "$KEY_PATH" ]; then
  log "Generating dedicated SSH keypair for Guacamole..."
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "guacamole@siem" -q
  ok "Keypair generated: ${KEY_PATH}"
else
  ok "SSH keypair already exists - reusing"
fi

log "Authorizing Guacamole's key for the vagrant user..."
VAGRANT_SSH_DIR="/home/vagrant/.ssh"
mkdir -p "$VAGRANT_SSH_DIR"
PUB_KEY=$(cat "${KEY_PATH}.pub")
if ! grep -qF "$PUB_KEY" "${VAGRANT_SSH_DIR}/authorized_keys" 2>/dev/null; then
  echo "$PUB_KEY" >> "${VAGRANT_SSH_DIR}/authorized_keys"
  ok "Public key added to vagrant's authorized_keys"
else
  ok "Public key already authorized"
fi
chown -R vagrant:vagrant "$VAGRANT_SSH_DIR"
chmod 700 "$VAGRANT_SSH_DIR"
chmod 600 "${VAGRANT_SSH_DIR}/authorized_keys"

# ── docker-compose.yml ─────────────────────────────────────────────────────
log "Writing docker-compose.yml..."
cat > "${GUAC_DIR}/docker-compose.yml" << 'EOF'
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: guacd
    network_mode: host
    restart: unless-stopped

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole
    network_mode: host
    restart: unless-stopped
    environment:
      GUACD_HOSTNAME: 127.0.0.1
      GUACD_PORT: "4822"
    volumes:
      - /opt/guacamole/user-mapping.xml:/etc/guacamole/user-mapping.xml:ro
EOF
ok "docker-compose.yml written"

# ── user-mapping.xml (single-user, no DB backend needed for a home lab) ──
log "Writing user-mapping.xml with connection profiles..."
PRIVATE_KEY=$(cat "$KEY_PATH")

cat > "${GUAC_DIR}/user-mapping.xml" << EOF
<user-mapping>
    <authorize username="admin" password="vagrant">

        <connection name="winserver - Administrator (Domain)">
            <protocol>rdp</protocol>
            <param name="hostname">${WSRV_IP}</param>
            <param name="port">3389</param>
            <param name="username">Administrator</param>
            <param name="password">vagrant</param>
            <param name="domain">${DOMAIN_NETBIOS}</param>
            <param name="security">nla</param>
            <param name="ignore-cert">true</param>
        </connection>

        <connection name="win11 - Administrator (Domain)">
            <protocol>rdp</protocol>
            <param name="hostname">${WIN11_IP}</param>
            <param name="port">3389</param>
            <param name="username">Administrator</param>
            <param name="password">vagrant</param>
            <param name="domain">${DOMAIN_NETBIOS}</param>
            <param name="security">nla</param>
            <param name="ignore-cert">true</param>
        </connection>

        <connection name="win11 - vagrant (Local)">
            <protocol>rdp</protocol>
            <param name="hostname">${WIN11_IP}</param>
            <param name="port">3389</param>
            <param name="username">vagrant</param>
            <param name="password">vagrant</param>
            <param name="security">nla</param>
            <param name="ignore-cert">true</param>
        </connection>

        <connection name="siem - SSH">
            <protocol>ssh</protocol>
            <param name="hostname">127.0.0.1</param>
            <param name="port">22</param>
            <param name="username">vagrant</param>
            <param name="private-key">${PRIVATE_KEY}</param>
        </connection>

        <connection name="kali - vagrant (SSH)">
            <protocol>ssh</protocol>
            <param name="hostname">${KALI_IP}</param>
            <param name="port">22</param>
            <param name="username">vagrant</param>
            <param name="password">vagrant</param>
        </connection>

    </authorize>
</user-mapping>
EOF
# 644, not 600: the guacamole container runs its Tomcat process as a
# non-root user (uid 1001), which cannot read a root-owned 600 file bind-
# mounted in - Docker bind mounts preserve host-side ownership/permissions
# as-is. Matches this lab's existing convention for credential files
# (logs/credentials.txt is also 644 - single-tenant lab VM, not multi-user).
chmod 644 "${GUAC_DIR}/user-mapping.xml"
ok "user-mapping.xml written (5 connections)"

{
  echo "# Guacamole Credentials - generated $(date)"
  echo "Web UI    : http://localhost:8280/guacamole"
  echo "Username  : admin"
  echo "Password  : vagrant"
} > "${LOG_DIR}/guacamole-credentials.txt"
ok "Credentials saved to logs/guacamole-credentials.txt"

# ── Start containers ──────────────────────────────────────────────────────
log "Starting guacd + guacamole containers..."
cd "$GUAC_DIR"
docker-compose up -d

log "Waiting for the Guacamole webapp to respond..."
for i in $(seq 1 24); do
  if curl -sf -o /dev/null "http://localhost:8080/guacamole/"; then
    ok "Guacamole webapp is responding"
    break
  fi
  log "  attempt $i/24 - waiting 5s..."
  sleep 5
done

log "--- Container status ---"
docker-compose ps

log "=========================================================="
log "  Guacamole setup COMPLETED"
log "  Web UI: http://localhost:8280/guacamole"
log "  Credentials: logs/guacamole-credentials.txt"
log "=========================================================="
