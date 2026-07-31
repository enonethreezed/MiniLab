#!/usr/bin/env bash
# MiniLab health check — Linux/macOS
# Verifies the SIEM (ELK by default, Splunk with ENABLE_SPLUNK=true, or Wazuh with ENABLE_WAZUH=true) and
# that the winserver/win11 endpoints are actually reporting into it.
#
# Run from the repo root (or anywhere — it locates logs/credentials.txt
# relative to this script) on the Vagrant host, after `vagrant up`.
set -uo pipefail

echo "Checking lab status:"
vagrant status
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $* =="; }

if [ "${ENABLE_SPLUNK:-}" = "true" ]; then
  section "SIEM: Splunk (ENABLE_SPLUNK=true)"
  echo "  [INFO] Delegating to tests/check-splunk.sh for full Splunk-mode checks"
  if bash "$SCRIPT_DIR/check-splunk.sh"; then
    pass "Splunk mode healthy (see output above)"
  else
    fail "Splunk mode NOT healthy (see output above)"
  fi
elif [ "${ENABLE_WAZUH:-}" = "true" ]; then
  section "SIEM: Wazuh (ENABLE_WAZUH=true)"
  echo "  [INFO] Delegating to tests/check-wazuh.sh for full Wazuh-mode checks"
  if bash "$SCRIPT_DIR/check-wazuh.sh"; then
    pass "Wazuh mode healthy (see output above)"
  else
    fail "Wazuh mode NOT healthy (see output above)"
  fi
else

CREDENTIALS_FILE="${CREDENTIALS_FILE:-$REPO_ROOT/logs/credentials.txt}"

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
ES_URL="${ES_URL:-http://localhost:9200}"
FLEET_URL="${FLEET_URL:-http://localhost:18220}"
EXPECTED_HOSTS="${EXPECTED_HOSTS:-siem WIN-SRV22 WIN11-WS01}"

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "Cannot find credentials file at $CREDENTIALS_FILE"
  echo "Set CREDENTIALS_FILE=/path/to/credentials.txt or run this after 'vagrant up siem'."
  exit 2
fi

ELASTIC_PASS=$(grep -oP '(?<=Password    : ).*' "$CREDENTIALS_FILE")
if [ -z "$ELASTIC_PASS" ]; then
  echo "Could not extract elastic password from $CREDENTIALS_FILE"
  exit 2
fi
AUTH=(-u "elastic:${ELASTIC_PASS}")

section "Elasticsearch ($ES_URL)"
ES_HEALTH=$(curl -sf "${AUTH[@]}" "$ES_URL/_cluster/health" 2>/dev/null)
if [ -n "$ES_HEALTH" ]; then
  STATUS=$(echo "$ES_HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
  if [ "$STATUS" = "green" ] || [ "$STATUS" = "yellow" ]; then
    pass "Elasticsearch reachable, cluster health: $STATUS"
  else
    fail "Elasticsearch reachable but cluster health: '$STATUS'"
  fi
else
  fail "Elasticsearch not reachable at $ES_URL"
fi

section "Kibana ($KIBANA_URL)"
KIBANA_STATUS=$(curl -sf "${AUTH[@]}" "$KIBANA_URL/api/status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('overall',{}).get('level',''))" 2>/dev/null)
if [ "$KIBANA_STATUS" = "available" ]; then
  pass "Kibana available"
else
  fail "Kibana status: '${KIBANA_STATUS:-unreachable}'"
fi

section "Fleet Server ($FLEET_URL)"
FLEET_STATUS=$(curl -sf "$FLEET_URL/api/status" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
if [ -n "$FLEET_STATUS" ]; then
  pass "Fleet Server reachable ($FLEET_STATUS)"
else
  fail "Fleet Server not reachable at $FLEET_URL"
fi

section "Fleet agent enrollment (Kibana console)"
AGENTS_JSON=$(curl -sf "${AUTH[@]}" -H "kbn-xsrf: true" "$KIBANA_URL/api/fleet/agents" 2>/dev/null)
if [ -z "$AGENTS_JSON" ]; then
  fail "Could not query Fleet agents API"
else
  # A lab that's been destroyed/recreated repeatedly can have multiple stale
  # agent records for the same hostname (each enrollment keeps its own Fleet
  # record). Keep only the most recently enrolled record per hostname.
  AGENT_LINES=$(echo "$AGENTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
latest = {}
for a in data.get('items', []):
    host = a.get('local_metadata', {}).get('host', {}).get('hostname', a.get('id'))
    enrolled_at = a.get('enrolled_at', '')
    if host not in latest or enrolled_at > latest[host][1]:
        latest[host] = (a.get('status', 'unknown'), enrolled_at)
for host, (status, _) in latest.items():
    print(f'{host}\t{status}')
" 2>/dev/null)

  if [ -z "$AGENT_LINES" ]; then
    fail "No agents enrolled in Fleet yet"
  else
    for expected in $EXPECTED_HOSTS; do
      LINE=$(echo "$AGENT_LINES" | grep -i "^${expected}$(printf '\t')" || true)
      if [ -z "$LINE" ]; then
        fail "Agent '$expected' not found in Fleet"
        continue
      fi
      HOST=$(echo "$LINE" | cut -f1)
      AGENT_STATUS=$(echo "$LINE" | cut -f2)
      if [ "$AGENT_STATUS" = "online" ]; then
        pass "Agent '$HOST' enrolled, status: online"
      else
        fail "Agent '$HOST' enrolled but status: $AGENT_STATUS"
      fi
    done
  fi
fi

section "Windows Endpoints integrations"
POLICY_ID=$(curl -sf "${AUTH[@]}" -H "kbn-xsrf: true" "$KIBANA_URL/api/fleet/agent_policies" 2>/dev/null \
  | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('items', []):
    if p.get('name') == 'Windows Endpoints':
        print(p['id']); break
" 2>/dev/null)

if [ -z "$POLICY_ID" ]; then
  fail "'Windows Endpoints' agent policy not found"
else
  # Fetched unfiltered and matched client-side: the Fleet API's kuery filter
  # for this endpoint requires a saved-object-type prefix
  # (ingest-package-policies.policy_id:<id>) that isn't worth depending on.
  PACKAGES=$(curl -sf "${AUTH[@]}" -H "kbn-xsrf: true" \
    "$KIBANA_URL/api/fleet/package_policies" 2>/dev/null \
    | python3 -c "
import sys, json
policy_id = '$POLICY_ID'
for pp in json.load(sys.stdin).get('items', []):
    if pp.get('policy_id') == policy_id:
        print(pp.get('package', {}).get('name', ''))
" 2>/dev/null)

  for pkg in system windows; do
    if echo "$PACKAGES" | grep -qx "$pkg"; then
      pass "Integration '$pkg' present on 'Windows Endpoints'"
    else
      fail "Integration '$pkg' missing from 'Windows Endpoints'"
    fi
  done
fi

fi  # ENABLE_SPLUNK / ENABLE_WAZUH

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  Lab is NOT fully healthy."
  exit 1
else
  echo "  Lab is healthy."
  exit 0
fi
