# Provisioning Windows 11 (workstation) - Elastic Agent enrollment (Fleet)
# SOC Blue Team Lab. Only runs when the siem VM is running ELK (default,
# ENABLE_SPLUNK not set). Requires win11-baseline.ps1 to have run first.

param(
  [string]$ELK_IP = "192.168.56.10"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$ToolsDir  = "C:\Tools"
$FleetURL  = "http://${ELK_IP}:8220"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-elastic-agent.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  Win11 Elastic Agent enrollment started  |  ELK: $ELK_IP"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

# -- 1. Wait for ELK enrollment token -----------------------------------------
$TokenFile = "C:\vagrant\logs\fleet-enrollment-token.txt"
log "Waiting for Fleet enrollment token from ELK (up to 10 min)..."
$waited = 0
while (-not (Test-Path $TokenFile) -or (Get-Content $TokenFile -Raw).Trim() -eq "") {
  if ($waited -ge 600) {
    err "Timed out waiting for fleet-enrollment-token.txt - enroll manually."
    Stop-Transcript; exit 1
  }
  Start-Sleep -Seconds 15
  $waited += 15
}
$FleetToken = (Get-Content $TokenFile -Raw).Trim()
ok "Fleet token received"

$VerFile = "C:\vagrant\logs\elastic-version.txt"
$AgentVer = if (Test-Path $VerFile) { (Get-Content $VerFile -Raw).Trim() } else { "8.13.4" }
log "Elastic Agent version: $AgentVer"

# -- 2. Elastic Agent ----------------------------------------------------------
$AgentUrl = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${AgentVer}-windows-x86_64.zip"
$AgentZip = "$ToolsDir\elastic-agent.zip"

log "Downloading Elastic Agent $AgentVer..."
Invoke-WebRequest -Uri $AgentUrl -OutFile $AgentZip -UseBasicParsing
ok "Elastic Agent downloaded"

log "Extracting Elastic Agent..."
Expand-Archive -Path $AgentZip -DestinationPath $ToolsDir -Force
$agentDir = Get-ChildItem -Path $ToolsDir -Directory -Filter "elastic-agent-*" | Select-Object -First 1
ok "Extracted to $($agentDir.FullName)"

# -- 3. Enroll with Fleet ------------------------------------------------------
log "Enrolling Elastic Agent with Fleet Server ($FleetURL)..."
& "$($agentDir.FullName)\elastic-agent.exe" install `
  --url="$FleetURL" `
  --enrollment-token="$FleetToken" `
  --insecure `
  --non-interactive

Start-Sleep -Seconds 10
$eaSvc = Get-Service -Name "Elastic Agent" -ErrorAction SilentlyContinue
if ($eaSvc -and $eaSvc.Status -eq "Running") { ok "Elastic Agent service: $($eaSvc.Status)" }
else { err "Elastic Agent service: $($eaSvc.Status)" }

# -- 4. Connectivity check -----------------------------------------------------
log "Connectivity checks..."
foreach ($port in @(8220, 9200, 5601)) {
  $r = Test-NetConnection -ComputerName $ELK_IP -Port $port -WarningAction SilentlyContinue
  if ($r.TcpTestSucceeded) { ok "TCP ${ELK_IP}:$port reachable" }
  else { err "TCP ${ELK_IP}:$port NOT reachable" }
}

# -- 5. Summary ----------------------------------------------------------------
log "--- Final service status ---"
$s = Get-Service -Name "Elastic Agent" -ErrorAction SilentlyContinue
if ($s) { log "  Elastic Agent: $($s.Status)" } else { err "  Elastic Agent not found" }
log "=========================================================="
log "  Win11 Elastic Agent enrollment COMPLETED"
log "  Elastic Agent: enrolled with Fleet -> $FleetURL"
log "  Full log:      logs/win11-elastic-agent.log"
log "=========================================================="

Stop-Transcript
