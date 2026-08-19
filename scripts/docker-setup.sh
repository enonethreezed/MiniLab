#!/usr/bin/env bash
# Docker Engine + Compose on elk (Debian Trixie)
# Generic infra step - not Guacamole-specific, so future services that also
# need Docker don't have to duplicate this.
set -euo pipefail

LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/docker-setup.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [DOCKER] $*"; }
ok()  { echo "[$(ts)] [OK]     $*"; }
err() { echo "[$(ts)] [ERR]    $*"; }

log "=========================================================="
log "  Docker setup started"
log "=========================================================="

if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null; then
  ok "Docker already installed and running - nothing to do"
  exit 0
fi

log "Installing docker.io + docker-compose (Debian's own packages, no third-party repo)..."
apt-get update -y -q
apt-get install -y -q docker.io docker-compose
ok "Packages installed"

log "Enabling and starting Docker..."
systemctl enable docker --quiet
systemctl start docker

log "Waiting for Docker daemon to be ready..."
for i in $(seq 1 12); do
  if docker info &>/dev/null; then
    ok "Docker daemon is ready"
    break
  fi
  log "  attempt $i/12 - waiting 5s..."
  sleep 5
done

log "Adding vagrant user to docker group..."
usermod -aG docker vagrant

DOCKER_VER=$(docker --version 2>/dev/null || echo "unknown")
COMPOSE_VER=$(docker-compose --version 2>/dev/null || echo "unknown")
ok "$DOCKER_VER"
ok "$COMPOSE_VER"

log "=========================================================="
log "  Docker setup COMPLETED"
log "=========================================================="
