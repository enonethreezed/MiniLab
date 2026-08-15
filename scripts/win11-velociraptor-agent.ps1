# Provisioning Windows 11 - Velociraptor client install
# SOC Blue Team Lab. Only runs when ENABLE_VELOCIRAPTOR=true. Requires
# velociraptor-provision.sh to have run on siem first (produces the
# pre-configured logs/velociraptor-client.msi).

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-velociraptor-agent.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  Win11 Velociraptor client install started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

# -- 1. Wait for the pre-configured MSI from siem -----------------------------
$MsiFile = "$LogDir\velociraptor-client.msi"
log "Waiting for logs/velociraptor-client.msi from siem (up to 10 min)..."
$waited = 0
while (-not (Test-Path $MsiFile)) {
  if ($waited -ge 600) {
    err "Timed out waiting for velociraptor-client.msi - install manually."
    Stop-Transcript; exit 1
  }
  Start-Sleep -Seconds 15
  $waited += 15
}
ok "velociraptor-client.msi received"

# -- 2. Install ------------------------------------------------------------------
log "Installing Velociraptor client (silent MSI, config already embedded)..."
$msiArgs = @("/i", "`"$MsiFile`"", "/quiet", "/norestart", "/l*v", "$LogDir\win11-velociraptor-msi.log")
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
  err "msiexec exited with code $($proc.ExitCode) - see logs/win11-velociraptor-msi.log"
  Stop-Transcript; exit 1
}
ok "MSI install completed"

Start-Sleep -Seconds 10
$svc = Get-Service -Name "Velociraptor" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") { ok "Velociraptor service: $($svc.Status)" }
else { err "Velociraptor service: $($svc.Status)" }

# -- 3. Summary ----------------------------------------------------------------
log "=========================================================="
log "  Win11 Velociraptor client install COMPLETED"
log "  Full log: logs/win11-velociraptor-agent.log"
log "=========================================================="

Stop-Transcript
