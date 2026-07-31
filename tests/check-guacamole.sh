#!/usr/bin/env bash
# MiniLab Guacamole health check — Linux/macOS
# Verifies the Guacamole HTML5 RDP/SSH gateway deployed on siem
# (ENABLE_GUACAMOLE=true). Run after `vagrant provision siem
# --provision-with docker-setup,guacamole-setup`.
set -uo pipefail

ELK_IP="${ELK_IP:-192.168.56.10}"
GUAC_URL="${GUAC_URL:-http://localhost:8280/guacamole}"
EXPECTED_CONNECTIONS=(
  "winserver - Administrator (Domain)"
  "win11 - Administrator (Domain)"
  "win11 - vagrant (Local)"
  "siem - SSH"
)

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

section "guacd (${ELK_IP}:4822)"
if (exec 3<>/dev/tcp/"${ELK_IP}"/4822) 2>/dev/null; then
  exec 3>&- 3<&-
  pass "guacd port 4822 reachable"
else
  fail "guacd port 4822 not reachable"
fi

section "Guacamole webapp ($GUAC_URL)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GUAC_URL}/" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
  pass "Guacamole webapp reachable (HTTP $HTTP_CODE)"
else
  fail "Guacamole webapp returned HTTP ${HTTP_CODE:-unreachable}"
fi

section "Web UI login (admin / vagrant)"
# The webapp being reachable (HTTP 200 above) does NOT mean login actually
# works - a permission-denied user-mapping.xml (e.g. unreadable by the
# container's non-root process) still serves a 200 login page while every
# login attempt fails. Authenticate via the REST API to catch that.
AUTH_RESP=$(curl -s -X POST "${GUAC_URL}/api/tokens" -d "username=admin&password=vagrant" 2>/dev/null)
if echo "$AUTH_RESP" | grep -q '"authToken"'; then
  pass "Logged in as admin/vagrant"
else
  fail "Login failed: $AUTH_RESP"
fi

section "Docker containers (over vagrant ssh)"
CONTAINERS=$(vagrant ssh siem -c "sudo docker ps --format '{{.Names}}:{{.Status}}'" 2>/dev/null)
for name in guacd guacamole; do
  if echo "$CONTAINERS" | grep -q "^${name}:Up"; then
    pass "Container '$name' is up"
  else
    fail "Container '$name' is not running"
  fi
done

section "Connection profiles (user-mapping.xml)"
MAPPING=$(vagrant ssh siem -c "sudo cat /opt/guacamole/user-mapping.xml" 2>/dev/null)
if [ -z "$MAPPING" ]; then
  fail "Could not read /opt/guacamole/user-mapping.xml"
else
  for conn in "${EXPECTED_CONNECTIONS[@]}"; do
    if echo "$MAPPING" | grep -qF "name=\"${conn}\""; then
      pass "Connection profile '$conn' present"
    else
      fail "Connection profile '$conn' missing"
    fi
  done
fi

section "siem - SSH connection (dedicated Guacamole keypair)"
SSH_KEY=$(vagrant ssh siem -c "sudo cat /opt/guacamole/ssh/guac_ed25519" 2>/dev/null)
if [ -z "$SSH_KEY" ]; then
  fail "Could not read Guacamole's SSH private key"
else
  TMP_KEY=$(mktemp)
  echo "$SSH_KEY" > "$TMP_KEY"
  chmod 600 "$TMP_KEY"
  WHOAMI=$(ssh -i "$TMP_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -p 2222 vagrant@127.0.0.1 "whoami" 2>/dev/null)
  rm -f "$TMP_KEY"
  if [ "$WHOAMI" = "vagrant" ]; then
    pass "SSH key authenticates as vagrant on siem"
  else
    fail "SSH key did not authenticate correctly"
  fi
fi

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Guacamole is NOT fully healthy."
  exit 1
else
  echo "  Guacamole is healthy."
  exit 0
fi
