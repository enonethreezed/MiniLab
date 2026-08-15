# Provisioning Windows Server 2022 - Windows Firewall logging
# SOC Blue Team Lab. Requires winserver-baseline.ps1 to have run first.
#
# File-based log (pfirewall.log), not a Windows Event Log channel - a
# different collection mechanism from every other telemetry source in this
# lab. Default log path already has the right ACLs for the firewall
# service (mpssvc) to write to, so it's kept as-is rather than redirected
# to a custom path.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$FirewallLog = "%systemroot%\system32\LogFiles\Firewall\pfirewall.log"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-firewall-logging.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }

log "=========================================================="
log "  WinServer Firewall logging setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

# 32767 KB (~32MB) is the hard cap for this log format - not the 100MB used
# for the eventchannel-based sources elsewhere in this lab.
Set-NetFirewallProfile -Profile Domain, Private, Public `
  -LogAllowed True -LogBlocked True `
  -LogFileName $FirewallLog -LogMaxSizeKilobytes 32767
ok "Firewall logging enabled (allowed + blocked) on all 3 profiles"
ok "Log file: $FirewallLog"

log "=========================================================="
log "  WinServer Firewall logging setup COMPLETED"
log "  Full log: logs/winserver-firewall-logging.log"
log "=========================================================="

Stop-Transcript
