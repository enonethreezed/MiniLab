#!/usr/bin/env bash
# Splunk mode health check (ENABLE_SPLUNK=1) — Linux/macOS
# Verifies Splunk Enterprise on the siem VM is actually usable, not just
# reachable: real login over the REST API, a license actually applied, and
# actual events arriving from the winserver/win11 forwarders (not just that
# port 9997 is open — see memory: feedback-verify-real-functionality, the
# Guacamole lesson: a reachable login page can still have every login fail).
#
# Run from the repo root after `ENABLE_SPLUNK=true vagrant up siem winserver win11`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-$REPO_ROOT/logs/splunk-credentials.txt}"

SPLUNK_WEB_URL="${SPLUNK_WEB_URL:-http://localhost:8000}"
SPLUNKD_URL="${SPLUNKD_URL:-https://localhost:8089}"
EXPECTED_HOSTS="${EXPECTED_HOSTS:-WIN-SRV22 WIN11-WS01}"

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "Cannot find credentials file at $CREDENTIALS_FILE"
  echo "Set CREDENTIALS_FILE=/path/to/splunk-credentials.txt or run this after"
  echo "'ENABLE_SPLUNK=true vagrant up siem'."
  exit 2
fi

SPLUNK_PASS=$(grep '^Password' "$CREDENTIALS_FILE" | sed 's/^Password[[:space:]]*:[[:space:]]*//' | tr -d '\r')
if [ -z "$SPLUNK_PASS" ]; then
  echo "Could not extract admin password from $CREDENTIALS_FILE"
  exit 2
fi
AUTH=(-u "admin:${SPLUNK_PASS}")

section "Splunk Web ($SPLUNK_WEB_URL)"
WEB_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$SPLUNK_WEB_URL/" 2>/dev/null)
if [ "$WEB_CODE" = "200" ] || [ "$WEB_CODE" = "303" ]; then
  pass "Splunk Web responding (HTTP $WEB_CODE)"
else
  fail "Splunk Web not responding as expected (HTTP ${WEB_CODE:-unreachable})"
fi

section "splunkd management API ($SPLUNKD_URL) — auth is actually enforced"
WRONG_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "admin:definitely-wrong-password" \
  "$SPLUNKD_URL/services/server/info" 2>/dev/null)
if [ "$WRONG_CODE" = "401" ]; then
  pass "Wrong credentials correctly rejected (HTTP 401)"
else
  fail "Expected HTTP 401 for wrong credentials, got ${WRONG_CODE:-unreachable} — auth may not be enforced"
fi

section "Real login (admin / credentials.txt password)"
LOGIN_CODE=$(curl -sk "${AUTH[@]}" -o /dev/null -w "%{http_code}" \
  "$SPLUNKD_URL/services/server/info" 2>/dev/null)
if [ "$LOGIN_CODE" = "200" ]; then
  pass "Logged in to splunkd REST API as admin"
else
  fail "Login failed (HTTP ${LOGIN_CODE:-unreachable}) — check splunk-provision.log on the siem VM"
fi

section "License mode"
# Splunk always has some license group active (Enterprise, Trial, or Free) —
# a missing/expired splunk/Splunk.License makes splunk-provision.sh fall
# back to Free/Trial mode by design (see MiniLab-cnu), so this reports the
# actual active mode rather than treating trial as a failure.
GROUPS_JSON=$(curl -sk "${AUTH[@]}" "$SPLUNKD_URL/services/licenser/groups?output_mode=json" 2>/dev/null)
ACTIVE_GROUP=$(echo "$GROUPS_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in data.get('entry', []):
    if e.get('content', {}).get('is_active'):
        print(e.get('name', ''))
        break
" 2>/dev/null)
if [ -n "$ACTIVE_GROUP" ]; then
  pass "Active license group: $ACTIVE_GROUP"
else
  fail "Could not determine active license group via REST API"
fi

run_search() {
  curl -sk "${AUTH[@]}" "$SPLUNKD_URL/services/search/jobs/export" \
    --data-urlencode "search=$1" \
    --data-urlencode "output_mode=json" \
    --data-urlencode "earliest_time=-24h" \
    --data-urlencode "latest_time=now" 2>/dev/null
}

section "Forwarder ingestion (real events indexed, not just TCP connected)"
for host in $EXPECTED_HOSTS; do
  RESP=$(run_search "search host=${host} | stats count as c")
  COUNT=$(echo "$RESP" | python3 -c "
import sys, json
c = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if 'result' in obj and 'c' in obj.get('result', {}):
        c = int(obj['result']['c'])
print(c)
" 2>/dev/null || echo 0)
  if [ "${COUNT:-0}" -gt 0 ]; then
    pass "Events indexed from host=$host (count=$COUNT)"
  else
    fail "No events indexed from host=$host yet (a fresh deploy can take a few minutes for the first events)"
  fi
done

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Splunk mode is NOT fully healthy."
  exit 1
else
  echo "  Splunk mode is healthy."
  exit 0
fi
