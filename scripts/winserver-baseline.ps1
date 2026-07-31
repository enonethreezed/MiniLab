# Provisioning Windows Server 2022 - baseline (Sysmon + Defender/Firewall)
# SOC Blue Team Lab

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$ToolsDir      = "C:\Tools"
$SysmonDir     = "$ToolsDir\sysmon"
$SysmonCfgUrl  = "https://raw.githubusercontent.com/olafhartong/sysmon-modular/master/sysmonconfig.xml"
$SysmonUrl     = "https://download.sysinternals.com/files/Sysmon.zip"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-baseline.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }
function err { param($m); Write-Host "$(ts) [ERR]     $m" }

log "=========================================================="
log "  WinServer baseline provisioning started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

New-Item -ItemType Directory -Force -Path $ToolsDir  | Out-Null
New-Item -ItemType Directory -Force -Path $SysmonDir | Out-Null

# -- 1. Sysmon (Olaf Hartong config) ------------------------------------------
log "Downloading Sysmon..."
Invoke-WebRequest -Uri $SysmonUrl -OutFile "$ToolsDir\Sysmon.zip" -UseBasicParsing
Expand-Archive -Path "$ToolsDir\Sysmon.zip" -DestinationPath $SysmonDir -Force
ok "Sysmon extracted"

log "Downloading Olaf Hartong sysmon-modular config..."
Invoke-WebRequest -Uri $SysmonCfgUrl -OutFile "$ToolsDir\sysmonconfig.xml" -UseBasicParsing
ok "Sysmon config downloaded"

log "Installing Sysmon64..."
$sysmonExe = Get-ChildItem -Path $SysmonDir -Filter "Sysmon64.exe" -Recurse | Select-Object -First 1
& $sysmonExe.FullName -accepteula -i "$ToolsDir\sysmonconfig.xml" | Out-Null

$svc = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") { ok "Sysmon64: $($svc.Status)" }
else { err "Sysmon64: $($svc.Status)" }

# -- 2. Windows Defender + Firewall --------------------------------------------
Add-MpPreference -ExclusionPath $ToolsDir -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Lab-ICMP-In" `
  -Direction Inbound -Protocol ICMPv4 -Action Allow `
  -RemoteAddress "192.168.56.0/24" -ErrorAction SilentlyContinue | Out-Null

# -- 3. Summary ----------------------------------------------------------------
log "--- Final service status ---"
$s = Get-Service -Name "Sysmon64" -ErrorAction SilentlyContinue
if ($s) { log "  Sysmon64: $($s.Status)" } else { err "  Sysmon64 not found" }
log "=========================================================="
log "  WinServer baseline provisioning COMPLETED"
log "  Sysmon:   Olaf Hartong config"
log "  RDP host: localhost:13389"
log "  Full log: logs/winserver-baseline.log"
log "=========================================================="

Stop-Transcript
