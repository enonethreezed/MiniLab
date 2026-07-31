#!/usr/bin/env bash
# Wazuh mode health check (ENABLE_WAZUH=1) — Linux/macOS
# Verifies Wazuh on the siem VM is actually usable, not just reachable: real
# login to the manager API, auth actually enforced, and real agents showing
# as active - not just that ports are open (see memory:
# feedback-verify-real-functionality, the Guacamole lesson).
#
# Run from the repo root after `ENABLE_WAZUH=true vagrant up siem winserver win11`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$REPO_ROOT/logs/wazuh-credentials.txt}"

DASHBOARD_URL="${DASHBOARD_URL:-https://localhost:4430}"
API_URL="${API_URL:-https://localhost:55000}"
EXPECTED_HOSTS="${EXPECTED_HOSTS:-WIN-SRV22 WIN11-WS01}"

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "Cannot find credentials file at $CREDENTIALS_FILE"
  echo "Set CREDENTIALS_FILE=/path/to/wazuh-credentials.txt or run this after"
  echo "'ENABLE_WAZUH=true vagrant up siem'."
  exit 2
fi

API_PASS=$(grep '^API password' "$CREDENTIALS_FILE" | sed 's/^API password[[:space:]]*:[[:space:]]*//' | tr -d '\r')
if [ -z "$API_PASS" ]; then
  echo "Could not extract API password from $CREDENTIALS_FILE"
  exit 2
fi

section "Wazuh dashboard ($DASHBOARD_URL)"
DASH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$DASHBOARD_URL/" 2>/dev/null)
if [ "$DASH_CODE" = "200" ] || [ "$DASH_CODE" = "302" ]; then
  pass "Dashboard responding (HTTP $DASH_CODE)"
else
  fail "Dashboard not responding as expected (HTTP ${DASH_CODE:-unreachable})"
fi

section "Manager API ($API_URL) — auth is actually enforced"
WRONG_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "wazuh:definitely-wrong-password" \
  -X POST "$API_URL/security/user/authenticate" 2>/dev/null)
if [ "$WRONG_CODE" = "401" ]; then
  pass "Wrong credentials correctly rejected (HTTP 401)"
else
  fail "Expected HTTP 401 for wrong credentials, got ${WRONG_CODE:-unreachable} — auth may not be enforced"
fi

section "Real login (wazuh API user / credentials.txt password)"
TOKEN=$(curl -sk -u "wazuh:${API_PASS}" -X POST "${API_URL}/security/user/authenticate?raw=true" 2>/dev/null)
if [ -n "$TOKEN" ] && ! echo "$TOKEN" | grep -qi "error\|unauthorized"; then
  pass "Logged in to the manager API as wazuh"
else
  fail "Login failed — check wazuh-provision.log on the siem VM"
fi

section "Agent enrollment (real status, not just port reachability)"
if [ -z "${TOKEN:-}" ]; then
  fail "Skipped — no auth token from the login step above"
else
  AGENTS_JSON=$(curl -sk -H "Authorization: Bearer ${TOKEN}" "${API_URL}/agents?select=name,status" 2>/dev/null)
  for host in $EXPECTED_HOSTS; do
    STATUS=$(echo "$AGENTS_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in data.get('data', {}).get('affected_items', []):
    if a.get('name', '').lower() == '$host'.lower():
        print(a.get('status', ''))
        break
" 2>/dev/null)
    if [ "$STATUS" = "active" ]; then
      pass "Agent '$host' active"
    else
      fail "Agent '$host' status: ${STATUS:-not found}"
    fi
  done
fi

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Wazuh mode is NOT fully healthy."
  exit 1
else
  echo "  Wazuh mode is healthy."
  exit 0
fi
