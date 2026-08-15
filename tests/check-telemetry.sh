#!/usr/bin/env bash
# MiniLab telemetry health check — Linux/macOS
#
# Verifies the distinction TELEMETRY.md keeps coming back to:
#   collector running  !=  collector running + telemetry actually arriving
#
# check-lab.sh confirms Elasticsearch/Kibana/Fleet are up and agents are
# enrolled - it doesn't tell you whether any of the specific data sources
# wired up across the TELEMETRY.md work (Sysmon, PowerShell, Defender, DNS,
# Firewall) are actually producing documents. This does, one query per
# source, for ELK mode.
#
# Run from the repo root on the Vagrant host, after `vagrant up` and after
# provisioning has had a few minutes to generate some natural activity
# (WinRM logons, Sysmon process creation, PowerShell script-block events
# from the provisioners' own execution, etc. all fire without needing you
# to do anything by hand).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  [PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $*"; SKIP=$((SKIP + 1)); }
section() { echo; echo "== $* =="; }

if [ "${ENABLE_SPLUNK:-}" = "true" ] || [ "${ENABLE_WAZUH:-}" = "true" ]; then
  echo "check-telemetry.sh only covers ELK mode for now (data-stream queries"
  echo "are ES-specific) - Splunk/Wazuh telemetry-arrival checks aren't"
  echo "implemented yet. Use check-splunk.sh / check-wazuh.sh for collector"
  echo "health in those modes; verify event arrival manually via the"
  echo "Splunk/Wazuh search UI for now."
  exit 2
fi

CREDENTIALS_FILE="${CREDENTIALS_FILE:-$REPO_ROOT/logs/credentials.txt}"
ES_URL="${ES_URL:-http://localhost:9200}"

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

# $1 = human label, $2 = index pattern, $3 = time window (ES date math)
check_arrival() {
  local label="$1" pattern="$2" window="${3:-now-24h}"
  local resp count
  resp=$(curl -sf "${AUTH[@]}" -H "Content-Type: application/json" \
    "$ES_URL/${pattern}/_count" \
    -d "{\"query\":{\"range\":{\"@timestamp\":{\"gte\":\"${window}\"}}}}" 2>/dev/null)
  if [ -z "$resp" ]; then
    fail "$label — index pattern '$pattern' not reachable (collector never configured or never wrote a document)"
    return
  fi
  count=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count', 0))" 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "0" ]; then
    fail "$label — index exists but 0 events since $window"
  else
    pass "$label — $count event(s) since $window"
  fi
}

section "Sysmon (process creation, network, etc.)"
check_arrival "Sysmon/Operational" "logs-windows.sysmon_operational-*"

section "PowerShell"
check_arrival "Script Block/Module Logging (4103/4104)" "logs-windows.powershell_operational-*"
check_arrival "Transcription (file-based)" "logs-powershell.transcripts-*"

section "Windows Defender"
check_arrival "Defender/Operational" "logs-windows.windows_defender-*"

section "DNS"
check_arrival "DNS-Server/Analytical (winserver only)" "logs-winlog.dns_server_analytical-*"
check_arrival "DNS-Client/Operational" "logs-winlog.dns_client_operational-*"

section "Windows Firewall"
check_arrival "pfirewall.log (file-based)" "logs-windows.firewall_log-*"

section "Windows Security (audit policy)"
# Security/Application/System channels are collected by the "system"
# integration (system-1), not "windows" - confirmed against the actual
# Elastic package docs: "Log collection for the Security, Application, and
# System event logs is handled by the System integration."
check_arrival "Security channel" "logs-system.security-*"

section "Summary"
echo "  Passed: $PASS   Failed: $FAIL   Skipped: $SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "  Telemetry pipeline is NOT fully healthy — collector configured but"
  echo "  some sources have produced nothing yet. On a freshly provisioned"
  echo "  lab this can be normal for low-frequency sources (DNS-Server/"
  echo "  Analytical, Firewall, Transcription) - give it a few minutes of"
  echo "  normal activity and re-run before assuming it's broken."
  exit 1
else
  echo "  Telemetry pipeline is healthy — every wired-up source has produced"
  echo "  at least one document."
  exit 0
fi
