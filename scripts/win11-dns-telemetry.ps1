# Provisioning Windows 11 (workstation) - DNS telemetry
# SOC Blue Team Lab. Requires win11-baseline.ps1 to have run first.
#
# win11 has no DNS Server role (that's winserver-dns-telemetry.ps1, DC
# only) - just DNS-Client/Operational, which every Windows host has and
# which is enabled by default already. Nothing to toggle, just give the
# channel more room than its default size.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-dns-telemetry.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }

log "=========================================================="
log "  Win11 DNS telemetry setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

wevtutil sl "Microsoft-Windows-DNS-Client/Operational" /ms:104857600
ok "DNS-Client/Operational channel size bumped to 100MB"

log "=========================================================="
log "  Win11 DNS telemetry setup COMPLETED"
log "  Full log: logs/win11-dns-telemetry.log"
log "=========================================================="

Stop-Transcript
