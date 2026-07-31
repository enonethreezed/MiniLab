# Provisioning Windows 11 (workstation) - Wazuh agent
# SOC Blue Team Lab. Only runs when the siem VM is running Wazuh
# (ENABLE_WAZUH=1). Requires win11-baseline.ps1 to have run first.

param(
  [string]$SIEM_IP = "192.168.56.10"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$ToolsDir  = "C:\Tools"
$AgentVer  = "4.14.6-1"
$AgentMsi  = "wazuh-agent-${AgentVer}.msi"
$AgentUrl  = "https://packages.wazuh.com/4.x/windows/${AgentMsi}"
$MsiPath   = "$ToolsDir\$AgentMsi"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-wazuh-agent.log"
New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  Win11 Wazuh agent setup started  |  SIEM: $SIEM_IP"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# -- 1. Wait for the registration password written by wazuh-provision.sh -------
$RegPassFile = "C:\vagrant\logs\wazuh-registration-password.txt"
log "Waiting for Wazuh registration password from siem (up to 10 min)..."
$waited = 0
while (-not (Test-Path $RegPassFile) -or (Get-Content $RegPassFile -Raw).Trim() -eq "") {
  if ($waited -ge 600) {
    err "Timed out waiting for wazuh-registration-password.txt - enroll manually."
    Stop-Transcript; exit 1
  }
  Start-Sleep -Seconds 15
  $waited += 15
}
$RegPass = (Get-Content $RegPassFile -Raw).Trim()
ok "Registration password received"

# -- 2. Download Wazuh agent -----------------------------------------------------
log "Downloading Wazuh agent $AgentVer..."
Invoke-WebRequest -Uri $AgentUrl -OutFile $MsiPath -UseBasicParsing
ok "Downloaded $AgentMsi"

# -- 3. Silent install + enroll ---------------------------------------------------
log "Installing and enrolling Wazuh agent with manager ($SIEM_IP)..."
$msiArgs = @(
  "/i", "`"$MsiPath`"",
  "/q",
  "WAZUH_MANAGER=`"$SIEM_IP`"",
  "WAZUH_REGISTRATION_SERVER=`"$SIEM_IP`"",
  "WAZUH_REGISTRATION_PASSWORD=`"$RegPass`""
)
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
  err "msiexec exited with code $($proc.ExitCode)"
  Stop-Transcript; exit 1
}
ok "Wazuh agent installed"

log "Starting WazuhSvc..."
Start-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
$svc = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") { ok "WazuhSvc: $($svc.Status)" }
else { err "WazuhSvc: $($svc.Status)" }

# -- 4. Summary -------------------------------------------------------------------
log "=========================================================="
log "  Win11 Wazuh agent setup COMPLETED"
log "  Manager:   $SIEM_IP"
log "  Full log:  logs/win11-wazuh-agent.log"
log "=========================================================="

Stop-Transcript
