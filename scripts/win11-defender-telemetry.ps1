# Provisioning Windows 11 (workstation) - Windows Defender Operational telemetry
# SOC Blue Team Lab. Requires win11-baseline.ps1 to have run first.
#
# Unlike PowerShell Script Block/Module Logging, there's no registry toggle
# to flip here - the Microsoft-Windows-Windows Defender/Operational channel
# logs threat detections, remediation, config/exclusion changes, and scan
# activity by default whenever Defender's real-time protection is on. This
# script just confirms that's actually the case and gives the channel more
# room than its default size.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-defender-telemetry.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  Win11 Defender telemetry setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

# -- 1. Confirm real-time protection is on -------------------------------------
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp -and $mp.RealTimeProtectionEnabled) {
  ok "Real-time protection: enabled"
} else {
  err "Real-time protection is NOT enabled - Defender/Operational will stay empty"
}

# -- 2. Room for the channel ----------------------------------------------------
# Default size fills up fast under any real testing, same reasoning as the
# PowerShell/Operational bump in win11-baseline.ps1.
wevtutil sl "Microsoft-Windows-Windows Defender/Operational" /ms:104857600
ok "Defender/Operational channel size bumped to 100MB"

# -- 3. Summary ----------------------------------------------------------------
log "=========================================================="
log "  Win11 Defender telemetry setup COMPLETED"
log "  Full log: logs/win11-defender-telemetry.log"
log "=========================================================="

Stop-Transcript
