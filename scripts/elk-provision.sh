#!/usr/bin/env bash
# ELK Stack 8.x + Fleet Server on Debian Bookworm
# Pipeline: Elastic Agent (Windows) -> Elasticsearch:9200 <- Kibana:5601
#           Fleet Server: http://ELK_IP:8220
set -euo pipefail

ELK_IP="${ELK_IP:-192.168.56.10}"
LOG_DIR="/vagrant/logs"
LOG_FILE="${LOG_DIR}/elk-provision.log"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] [ELK]  $*"; }
ok()  { echo "[$(ts)] [OK]   $*"; }
err() { echo "[$(ts)] [ERR]  $*"; }

log "==========================================================="
log "  ELK + Fleet Server provisioning started"
log "  Log: ${LOG_FILE} (synced to Vagrant host)"
log "==========================================================="

# ── 0. Base packages ──────────────────────────────────────────────────────────
log "Installing prerequisites..."
apt-get update -y -q
apt-get install -y -q apt-transport-https wget curl gnupg lsb-release python3
ok "Prerequisites installed"

# ── 1. Elastic 8.x repo ───────────────────────────────────────────────────────
log "Adding Elastic 8.x apt repository..."
if [ ! -f /usr/share/keyrings/elasticsearch-keyring.gpg ]; then
  wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --batch --no-tty --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
fi

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

apt-get update -y -q
ok "Elastic repository added"

# ── 2. Elasticsearch (security ON — required for Fleet) ───────────────────────
log "Installing Elasticsearch..."
apt-get install -y elasticsearch

ELASTIC_VER=$(dpkg-query -W -f='${Version}' elasticsearch | cut -d'-' -f1)
log "Detected version: ${ELASTIC_VER}"
echo "${ELASTIC_VER}" > "${LOG_DIR}/elastic-version.txt"

cat > /etc/elasticsearch/elasticsearch.yml << EOF
cluster.name: soc-lab
node.name: elk-node-1
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node

# Security ON (needed for Fleet), TLS OFF (lab network)
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options << 'EOF'
-Xms3g
-Xmx3g
EOF

log "Starting Elasticsearch..."
systemctl daemon-reload
systemctl enable elasticsearch --quiet
systemctl start elasticsearch

log "Waiting for Elasticsearch..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9200 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then break; fi
  log "  attempt $i/30 — waiting 10s..."
  sleep 10
done

# Generate elastic superuser password
log "Generating elastic user password..."
RESET_OUTPUT=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic --batch 2>&1)
ELASTIC_PASS=$(echo "$RESET_OUTPUT" | grep -oP '(?<=New value: )\S+')

if [ -z "$ELASTIC_PASS" ]; then
  err "Could not extract password from: $RESET_OUTPUT"
  exit 1
fi
ok "Elastic password generated"

# Kibana must NOT authenticate as the "elastic" superuser — ES 8.x rejects it
# ("this is a superuser account that cannot write to system indices that
# Kibana needs to function"). Use the built-in kibana_system service account.
log "Generating kibana_system user password..."
KIBANA_RESET_OUTPUT=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u kibana_system --batch 2>&1)
KIBANA_SYSTEM_PASS=$(echo "$KIBANA_RESET_OUTPUT" | grep -oP '(?<=New value: )\S+')

if [ -z "$KIBANA_SYSTEM_PASS" ]; then
  err "Could not extract kibana_system password from: $KIBANA_RESET_OUTPUT"
  exit 1
fi
ok "kibana_system password generated"

# Save credentials so user knows how to log in
{
  echo "# ELK Lab Credentials — generated $(date)"
  echo "Kibana URL  : http://localhost:5601  (or http://${ELK_IP}:5601)"
  echo "Username    : elastic"
  echo "Password    : ${ELASTIC_PASS}"
  echo ""
  echo "kibana_system password (internal, Kibana -> ES auth): ${KIBANA_SYSTEM_PASS}"
  echo ""
  echo "Fleet Server: http://${ELK_IP}:8220"
} > "${LOG_DIR}/credentials.txt"
ok "Credentials saved to logs/credentials.txt"

# Verify auth works
for i in $(seq 1 12); do
  if curl -sf -u "elastic:${ELASTIC_PASS}" http://localhost:9200/_cluster/health > /dev/null 2>&1; then
    HEALTH=$(curl -sf -u "elastic:${ELASTIC_PASS}" http://localhost:9200/_cluster/health \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    ok "Elasticsearch ready — cluster health: ${HEALTH}"
    break
  fi
  sleep 5
done

# ── 3. Kibana ─────────────────────────────────────────────────────────────────
log "Installing Kibana..."
apt-get install -y kibana

cat > /etc/kibana/kibana.yml << EOF
server.port: 5601
server.host: "0.0.0.0"
server.name: "soc-kibana"
elasticsearch.hosts: ["http://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_SYSTEM_PASS}"
i18n.locale: "en"

logging:
  appenders:
    file:
      type: file
      fileName: /var/log/kibana/kibana.log
      layout:
        type: json
  root:
    appenders: [default, file]
    level: info
EOF

mkdir -p /var/log/kibana
chown kibana:kibana /var/log/kibana

log "Starting Kibana..."
systemctl enable kibana --quiet
systemctl restart kibana
ok "Kibana started"

# ── 4. Logstash (optional — available for non-Agent sources) ──────────────────
log "Installing Logstash..."
apt-get install -y logstash

cat > /etc/logstash/conf.d/01-beats-input.conf << 'EOF'
input {
  beats { port => 5044 }
}
EOF

cat > /etc/logstash/conf.d/90-elasticsearch-output.conf << EOF
output {
  elasticsearch {
    hosts           => ["http://localhost:9200"]
    user            => "elastic"
    password        => "${ELASTIC_PASS}"
    index           => "%{[@metadata][beat]}-%{[@metadata][version]}-%{+YYYY.MM.dd}"
    manage_template => false
  }
}
EOF

sed -i 's/^-Xms1g/-Xms512m/' /etc/logstash/jvm.options
systemctl enable logstash --quiet
systemctl restart logstash
ok "Logstash started"

# ── 5. Kibana Fleet setup ───────────────────────────────────────────────────────
# Must run BEFORE installing the Fleet Server agent: Kibana's /api/fleet/setup
# call is what creates the default agent policy with the Fleet Server
# integration attached. Without it, the elastic-agent enroll below has no
# policy to join and times out waiting for one (see MiniLab bug: Fleet Server
# enroll timeout).
log "Waiting for Kibana to fully start (may take 3-5 min)..."
KIBANA_AVAILABLE=false
for i in $(seq 1 36); do
  STATUS=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    http://localhost:5601/api/status 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('overall',{}).get('level',''))" 2>/dev/null || true)
  if [ "$STATUS" = "available" ]; then
    ok "Kibana is available"
    KIBANA_AVAILABLE=true
    break
  fi
  log "  Kibana status: '${STATUS}' — waiting 10s... ($i/36)"
  sleep 10
done

if [ "$KIBANA_AVAILABLE" != "true" ]; then
  err "Kibana never became available — check 'journalctl -u kibana' on the elk VM"
  exit 1
fi

log "Triggering Fleet setup..."
FLEET_INITIALIZED=false
for i in $(seq 1 12); do
  SETUP_RESP=$(curl -sf -X POST "http://localhost:5601/api/fleet/setup" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -u "elastic:${ELASTIC_PASS}" 2>/dev/null || true)
  IS_INIT=$(echo "$SETUP_RESP" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('isInitialized','false'))" 2>/dev/null || echo "false")
  if [ "$IS_INIT" = "True" ] || [ "$IS_INIT" = "true" ]; then
    ok "Fleet initialized"
    FLEET_INITIALIZED=true
    break
  fi
  log "  Fleet not ready yet... ($i/12)"
  sleep 15
done

if [ "$FLEET_INITIALIZED" != "true" ]; then
  err "Fleet setup never completed — check Kibana logs on the elk VM"
  exit 1
fi

# POST /api/fleet/setup only sets up Fleet's internal indices/config — it does
# NOT create a default Fleet Server policy in this Elastic version. Without an
# explicit policy that has_fleet_server: true, the elastic-agent Fleet Server
# enroll below hangs on "Waiting on default policy with Fleet Server
# integration" and times out after 2 minutes.
log "Creating Fleet Server policy..."
FLEET_POLICY_RESP=$(curl -sf -X POST "http://localhost:5601/api/fleet/agent_policies" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "elastic:${ELASTIC_PASS}" \
  -d '{"name":"Fleet Server Policy","namespace":"default","has_fleet_server":true}' 2>/dev/null || true)
FLEET_SERVER_POLICY_ID=$(echo "$FLEET_POLICY_RESP" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || true)

if [ -z "$FLEET_SERVER_POLICY_ID" ]; then
  # Already exists (re-provision) — look up the existing Fleet Server policy
  FLEET_SERVER_POLICY_ID=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/agent_policies" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('items', []):
    if p.get('is_default_fleet_server'):
        print(p['id']); break
" 2>/dev/null || true)
fi

if [ -z "$FLEET_SERVER_POLICY_ID" ]; then
  err "Could not create or find a Fleet Server policy. Response: $FLEET_POLICY_RESP"
  exit 1
fi
ok "Fleet Server policy: ${FLEET_SERVER_POLICY_ID}"

# ── 6. Fleet Server ───────────────────────────────────────────────────────────
log "Downloading Elastic Agent ${ELASTIC_VER} for Fleet Server..."
wget -q "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELASTIC_VER}-linux-x86_64.tar.gz" \
  -O /tmp/elastic-agent.tar.gz
tar -xzf /tmp/elastic-agent.tar.gz -C /tmp/
ok "Elastic Agent downloaded"

log "Creating Fleet Server service token..."
# Delete token if it already exists (idempotency on re-provision)
curl -sf -X DELETE \
  "http://localhost:9200/_security/service/elastic/fleet-server/credential/token/lab-token" \
  -u "elastic:${ELASTIC_PASS}" > /dev/null 2>&1 || true

TOKEN_RESP=$(curl -sf -X POST \
  "http://localhost:9200/_security/service/elastic/fleet-server/credential/token/lab-token" \
  -u "elastic:${ELASTIC_PASS}" \
  -H "Content-Type: application/json")
SERVICE_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['value'])" 2>/dev/null)

if [ -z "$SERVICE_TOKEN" ]; then
  err "Failed to create service token. Response: $TOKEN_RESP"
  exit 1
fi
ok "Service token created"

# Uninstall existing elastic-agent if present (idempotency on re-provision)
if systemctl is-active elastic-agent &>/dev/null || [ -f /opt/Elastic/Agent/elastic-agent ]; then
  log "Elastic Agent already installed — uninstalling for re-provision..."
  /opt/Elastic/Agent/elastic-agent uninstall --force 2>/dev/null || \
    elastic-agent uninstall --force 2>/dev/null || true
  sleep 5
fi

log "Installing Fleet Server (elastic-agent) on port 8220..."
/tmp/elastic-agent-${ELASTIC_VER}-linux-x86_64/elastic-agent install \
  --fleet-server-es="http://127.0.0.1:9200" \
  --fleet-server-service-token="${SERVICE_TOKEN}" \
  --fleet-server-policy="${FLEET_SERVER_POLICY_ID}" \
  --fleet-server-host=0.0.0.0 \
  --fleet-server-port=8220 \
  --fleet-server-insecure-http \
  --non-interactive

log "Waiting for Fleet Server on :8220..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8220/api/status > /dev/null 2>&1; then
    ok "Fleet Server is ready"
    break
  fi
  log "  attempt $i/30..."
  sleep 10
done

# POST /api/fleet/setup creates the default output pointing at Kibana's own
# elasticsearch.hosts, i.e. "http://localhost:9200" - correct for Fleet
# Server (co-located on this VM) but unreachable for the remote Windows
# agents, whose own localhost has nothing listening on :9200. Every
# Fleet-managed integration (system-1, windows-1, elastic-agent monitoring)
# ships through this output, so left as localhost it silently produces zero
# logs-*/metrics-* data from the Windows endpoints (see MiniLab-w30).
log "Pointing the default Fleet output at ${ELK_IP} (not localhost)..."
curl -sf -X PUT "http://localhost:5601/api/fleet/outputs/fleet-default-output" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -u "elastic:${ELASTIC_PASS}" \
  -d "{\"name\":\"default\",\"type\":\"elasticsearch\",
       \"hosts\":[\"http://${ELK_IP}:9200\"],
       \"is_default\":true,\"is_default_monitoring\":true}" > /dev/null 2>&1 \
  && ok "Default Fleet output now points at http://${ELK_IP}:9200" \
  || err "Could not update the default Fleet output - Windows agents may fail to ship data"

# ── 7. Windows Endpoints agent policy + enrollment token ──────────────────────
log "Creating 'Windows Endpoints' agent policy..."
POLICY_RESP=$(curl -sf -X POST "http://localhost:5601/api/fleet/agent_policies" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "elastic:${ELASTIC_PASS}" \
  -d '{
    "name": "Windows Endpoints",
    "namespace": "default",
    "description": "WinServer + Win11 — SOC Blue Team lab",
    "monitoring_enabled": ["logs", "metrics"]
  }' 2>/dev/null || true)
POLICY_ID=$(echo "$POLICY_RESP" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || true)

if [ -z "$POLICY_ID" ]; then
  # Already exists (re-provision, HTTP 409) — look up its id by name instead
  # of failing. Without this, set -e aborts the whole script on re-provision.
  POLICY_ID=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/agent_policies" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('items', []):
    if p.get('name') == 'Windows Endpoints':
        print(p['id']); break
" 2>/dev/null || true)
fi

if [ -z "$POLICY_ID" ]; then
  err "Could not create or find 'Windows Endpoints' agent policy — getting default enrollment token instead"
  ENROLLMENT_TOKEN=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/enrollment-api-keys" \
    -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "
import sys, json
for k in json.load(sys.stdin).get('items', []):
    if k.get('active') and 'fleet-server' not in k.get('name','').lower():
        print(k['api_key']); break
" 2>/dev/null || true)
else
  ok "Agent policy created: ${POLICY_ID}"
  echo "${POLICY_ID}" > "${LOG_DIR}/fleet-policy-id.txt"

  # The Fleet package registry rejects the literal string "latest" as a
  # version — it must be a real semver. Look up the current version of each
  # integration package before creating its package policy.
  SYSTEM_PKG_VER=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/epm/packages/system" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null || true)
  WINDOWS_PKG_VER=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/epm/packages/windows" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null || true)
  WINLOG_PKG_VER=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/epm/packages/winlog" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null || true)
  # "log" ("Custom Logs"), not the newer "filestream" package - filestream
  # requires Kibana ^9.4.0, this lab pins ELK/Kibana 8.x (see the apt repo
  # added at the top of this script). "log" is marked Deprecated in the
  # registry but is the only file-based custom-log input compatible with
  # 8.x (its own manifest declares "^8.8.0 || ^9.0.0").
  LOG_PKG_VER=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/epm/packages/log" -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null || true)

  # POST/PUT helper for Fleet API calls (MiniLab-cgx) - curl -f discards the
  # response body on 4xx/5xx, which is exactly the useful part for diagnosing
  # a failure. Captures HTTP status + body in $FLEET_REQUEST_BODY so a
  # failing call logs the real reason instead of just "manual config
  # needed", without having to repeat this boilerplate at every call site.
  fleet_request() {
    local method="$1" url="$2" body="$3"
    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' -X "$method" "$url" \
      -H "kbn-xsrf: true" -H "Content-Type: application/json" \
      -u "elastic:${ELASTIC_PASS}" -d "$body" 2>&1)
    http_code=$(echo "$resp" | tail -n1)
    FLEET_REQUEST_BODY=$(echo "$resp" | sed '$d')
    [[ "$http_code" =~ ^2[0-9][0-9]$ ]]
  }

  # Add System integration. Deliberately omit "inputs" - Kibana then derives
  # the full default input/stream config from the package manifest (metrics
  # AND logs streams enabled per their defaults). Passing "inputs":[]
  # explicitly disables every stream instead of using defaults - it silently
  # produced zero logs-* data and metrics-* limited to Fleet's own internal
  # agent-status telemetry (see MiniLab-w30).
  if fleet_request POST "http://localhost:5601/api/fleet/package_policies" \
    "{\"name\":\"system-1\",\"policy_id\":\"${POLICY_ID}\",
      \"package\":{\"name\":\"system\",\"version\":\"${SYSTEM_PKG_VER}\"},
      \"namespace\":\"default\"}"
  then
    ok "System integration added"
  else
    log "System integration: manual config needed ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
  fi

  # Add Windows integration (event logs, Sysmon, PowerShell, etc.) - same
  # reasoning: omit "inputs" so Kibana fills in the package defaults.
  if fleet_request POST "http://localhost:5601/api/fleet/package_policies" \
    "{\"name\":\"windows-1\",\"policy_id\":\"${POLICY_ID}\",
      \"package\":{\"name\":\"windows\",\"version\":\"${WINDOWS_PKG_VER}\"},
      \"namespace\":\"default\"}"
  then
    WINDOWS_PP_RESP="$FLEET_REQUEST_BODY"
    ok "Windows integration added"

    # windows_defender ships with the package's own default "enabled: false"
    # (unlike powershell_operational/sysmon_operational, which have no
    # enabled key and default on) - flip it on with a GET/POST-response
    # modify-PUT round trip using Kibana's own resolved inputs as the base,
    # not a hand-built "inputs" array. A hand-built partial array is exactly
    # what silently disabled everything else in MiniLab-w30 - PUT requires
    # the full inputs list, and the POST response already contains it fully
    # resolved with every stream's real default state.
    WINDOWS_PP_ID=$(echo "$WINDOWS_PP_RESP" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || true)
    if [ -n "$WINDOWS_PP_ID" ]; then
      UPDATED_PP=$(echo "$WINDOWS_PP_RESP" | python3 -c "
import sys, json
item = json.load(sys.stdin)['item']
for inp in item.get('inputs', []):
    for stream in inp.get('streams', []):
        if stream.get('data_stream', {}).get('dataset') == 'windows.windows_defender':
            stream['enabled'] = True
            inp['enabled'] = True
for k in ('id', 'revision', 'created_at', 'created_by', 'updated_at',
          'updated_by', 'elasticsearch', 'version'):
    item.pop(k, None)
print(json.dumps(item))
" 2>/dev/null || true)
      if [ -n "$UPDATED_PP" ]; then
        if fleet_request PUT "http://localhost:5601/api/fleet/package_policies/${WINDOWS_PP_ID}" "$UPDATED_PP"; then
          ok "Windows Defender Operational stream enabled"
        else
          log "Windows Defender stream: manual enable needed (Fleet -> Windows Endpoints -> windows-1 -> Windows Defender) ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
        fi
      fi
    fi
  else
    log "Windows integration: manual config needed ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
  fi

  # DNS channels (MiniLab-qju) - neither the "windows" package nor any other
  # bundled Elastic integration ships a DNS-Server/DNS-Client data stream
  # (confirmed: no dns_server/dns_client entry in the windows package, and no
  # dedicated windows_dns_server package exists in the registry). The
  # supported way to collect an arbitrary Windows Event Log channel Elastic
  # doesn't already model is the "winlog" *input* package ("Custom Windows
  # Event Logs") - unlike "windows"/"system" it has no streams of its own, so
  # "inputs" can't be omitted here; the channel name and dataset are
  # required vars. Applied to the same shared "Windows Endpoints" policy as
  # everything else, so win11 also subscribes to DNS-Server/Analytical even
  # though it's not a DNS server - Elastic Agent just sees an empty channel
  # there and produces no events for it, harmless but not clean.
  add_winlog_channel() {
    # $1 = package_policy name, $2 = channel, $3 = dataset
    fleet_request POST "http://localhost:5601/api/fleet/package_policies" \
      "{\"name\":\"$1\",\"policy_id\":\"${POLICY_ID}\",
        \"package\":{\"name\":\"winlog\",\"version\":\"${WINLOG_PKG_VER}\"},
        \"namespace\":\"default\",
        \"inputs\":[{\"type\":\"winlog\",\"policy_template\":\"winlogs\",\"enabled\":true,
          \"streams\":[{\"enabled\":true,
            \"data_stream\":{\"type\":\"logs\",\"dataset\":\"$3\"},
            \"vars\":{
              \"channel\":{\"type\":\"text\",\"value\":\"$2\"},
              \"data_stream.dataset\":{\"type\":\"text\",\"value\":\"$3\"}
            }}]}]}"
  }

  if [ -n "$WINLOG_PKG_VER" ]; then
    if add_winlog_channel "dns-server-analytical-1" \
      "Microsoft-Windows-DNS-Server/Analytical" "winlog.dns_server_analytical"
    then
      ok "DNS-Server/Analytical winlog input added"
    else
      log "DNS-Server/Analytical: manual config needed (Fleet -> Windows Endpoints -> Add integration -> Custom Windows Event Logs) ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
    fi

    if add_winlog_channel "dns-client-operational-1" \
      "Microsoft-Windows-DNS-Client/Operational" "winlog.dns_client_operational"
    then
      ok "DNS-Client/Operational winlog input added"
    else
      log "DNS-Client/Operational: manual config needed (Fleet -> Windows Endpoints -> Add integration -> Custom Windows Event Logs) ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
    fi
  else
    log "winlog package version lookup failed - DNS channels need manual config"
  fi

  # PowerShell Transcription (MiniLab-w5t) - plain-text files, not an event
  # channel, so neither "windows" nor "winlog" apply. C:\PSTranscripts is
  # created by winserver/win11-powershell-transcription.ps1; path uses
  # forward slashes since Filebeat/Elastic Agent accept them on Windows too
  # and it avoids JSON backslash-escaping headaches in this script.
  if [ -n "$LOG_PKG_VER" ]; then
    if fleet_request POST "http://localhost:5601/api/fleet/package_policies" \
      "{\"name\":\"powershell-transcripts-1\",\"policy_id\":\"${POLICY_ID}\",
        \"package\":{\"name\":\"log\",\"version\":\"${LOG_PKG_VER}\"},
        \"namespace\":\"default\",
        \"inputs\":[{\"type\":\"logfile\",\"policy_template\":\"logs\",\"enabled\":true,
          \"streams\":[{\"enabled\":true,
            \"data_stream\":{\"type\":\"logs\",\"dataset\":\"powershell.transcripts\"},
            \"vars\":{
              \"paths\":{\"type\":\"text\",\"value\":[\"C:/PSTranscripts/*.txt\"]},
              \"data_stream.dataset\":{\"type\":\"text\",\"value\":\"powershell.transcripts\"}
            }}]}]}"
    then
      ok "PowerShell Transcription file input added"
    else
      log "PowerShell Transcription: manual config needed (Fleet -> Windows Endpoints -> Add integration -> Custom Logs (Deprecated)) ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
    fi
  else
    log "log package version lookup failed - PowerShell Transcription needs manual config"
  fi

  # Windows Firewall logging (MiniLab-nub) - same "log" package as
  # Transcription above, another plain-text file (pfirewall.log, W3C
  # extended log format), not an event channel.
  if [ -n "$LOG_PKG_VER" ]; then
    if fleet_request POST "http://localhost:5601/api/fleet/package_policies" \
      "{\"name\":\"firewall-log-1\",\"policy_id\":\"${POLICY_ID}\",
        \"package\":{\"name\":\"log\",\"version\":\"${LOG_PKG_VER}\"},
        \"namespace\":\"default\",
        \"inputs\":[{\"type\":\"logfile\",\"policy_template\":\"logs\",\"enabled\":true,
          \"streams\":[{\"enabled\":true,
            \"data_stream\":{\"type\":\"logs\",\"dataset\":\"windows.firewall_log\"},
            \"vars\":{
              \"paths\":{\"type\":\"text\",\"value\":[\"C:/Windows/System32/LogFiles/Firewall/pfirewall.log\"]},
              \"data_stream.dataset\":{\"type\":\"text\",\"value\":\"windows.firewall_log\"}
            }}]}]}"
    then
      ok "Windows Firewall log file input added"
    else
      log "Windows Firewall log: manual config needed (Fleet -> Windows Endpoints -> Add integration -> Custom Logs (Deprecated)) ($(echo "$FLEET_REQUEST_BODY" | tr -d '\n' | cut -c1-300))"
    fi
  else
    log "log package version lookup failed - Windows Firewall log needs manual config"
  fi

  # Get enrollment token for the policy. The filter query param is
  # "kuery=policy_id:<id>", NOT "policyId=<id>" (that name returns a 400).
  ENROLLMENT_TOKEN=$(curl -sf -u "elastic:${ELASTIC_PASS}" \
    "http://localhost:5601/api/fleet/enrollment-api-keys?kuery=policy_id:${POLICY_ID}" \
    -H "kbn-xsrf: true" 2>/dev/null \
    | python3 -c "
import sys, json
for k in json.load(sys.stdin).get('items', []):
    if k.get('active'):
        print(k['api_key']); break
" 2>/dev/null || true)
fi

if [ -n "$ENROLLMENT_TOKEN" ]; then
  echo "$ENROLLMENT_TOKEN" > "${LOG_DIR}/fleet-enrollment-token.txt"
  ok "Enrollment token saved to logs/fleet-enrollment-token.txt"
else
  err "Could not get enrollment token — Windows agents will need manual enrollment"
  echo "" > "${LOG_DIR}/fleet-enrollment-token.txt"
fi

# ── 8. Firewall ───────────────────────────────────────────────────────────────
if command -v ufw &> /dev/null; then
  ufw allow 5601/tcp comment "Kibana"         > /dev/null 2>&1 || true
  ufw allow 9200/tcp comment "Elasticsearch"  > /dev/null 2>&1 || true
  ufw allow 5044/tcp comment "Logstash-Beats" > /dev/null 2>&1 || true
  ufw allow 8220/tcp comment "Fleet Server"   > /dev/null 2>&1 || true
fi

# ── 9. Final status ───────────────────────────────────────────────────────────
log "--- Service status ---"
for svc in elasticsearch kibana logstash elastic-agent; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
  if [ "$STATUS" = "active" ]; then ok "$svc: $STATUS"
  else err "$svc: $STATUS"; fi
done

log "==========================================================="
log "  ELK + Fleet Server READY"
log "  Kibana        : http://localhost:5601"
log "  Elasticsearch : http://${ELK_IP}:9200"
log "  Fleet Server  : http://${ELK_IP}:8220"
log "  Credentials   : logs/credentials.txt"
log "  Enroll token  : logs/fleet-enrollment-token.txt"
log "  Full log      : logs/elk-provision.log"
log "==========================================================="
log "  To add Elastic Defend (monitor/protect mode):"
log "  Fleet -> Agent Policies -> Windows Endpoints -> Add integration"
log "  -> 'Elastic Defend' -> choose 'EDR Complete' preset"
log "==========================================================="
