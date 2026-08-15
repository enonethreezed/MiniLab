# Provisioning Windows Server 2022 - Splunk Universal Forwarder
# SOC Blue Team Lab. Only runs when the siem VM is running Splunk
# (ENABLE_SPLUNK=1). Requires winserver-baseline.ps1 to have run first.

param(
  [string]$SIEM_IP = "192.168.56.10"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$ToolsDir   = "C:\Tools"
$UfVer      = "10.4.1"
$UfBuild    = "5a009d941268"
$UfMsi      = "splunkforwarder-${UfVer}-${UfBuild}-windows-x64.msi"
$UfUrl      = "https://download.splunk.com/products/universalforwarder/releases/${UfVer}/windows/${UfMsi}"
$UfMsiPath  = "$ToolsDir\$UfMsi"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-splunk-forwarder.log"
New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }
function err { param($m); Write-Host "$(ts) [ERR]     $m" }

log "=========================================================="
log "  WinServer Splunk Universal Forwarder setup started  |  SIEM: $SIEM_IP"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# -- 1. Indexer reachability (soft check - UF retries on its own regardless) --
log "Checking receiving port on ${SIEM_IP}:9997..."
$r = Test-NetConnection -ComputerName $SIEM_IP -Port 9997 -WarningAction SilentlyContinue
if ($r.TcpTestSucceeded) { ok "TCP ${SIEM_IP}:9997 reachable" }
else { log "  TCP ${SIEM_IP}:9997 not reachable yet - forwarder will retry after install" }

# -- 2. Download Universal Forwarder --------------------------------------------
log "Downloading Splunk Universal Forwarder $UfVer..."
Invoke-WebRequest -Uri $UfUrl -OutFile $UfMsiPath -UseBasicParsing
ok "Downloaded $UfMsi"

# -- 3. Silent install ------------------------------------------------------------
$AdminPass = "Wf" + -join ((48..57) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ }) + "9!"

log "Installing Splunk Universal Forwarder..."
$msiArgs = @(
  "/i", "`"$UfMsiPath`"",
  "AGREETOLICENSE=Yes",
  "RECEIVING_INDEXER=`"${SIEM_IP}:9997`"",
  "WINEVENTLOG_APP_ENABLE=1",
  "WINEVENTLOG_SEC_ENABLE=1",
  "WINEVENTLOG_SYS_ENABLE=1",
  "LAUNCHSPLUNK=1",
  "SPLUNKUSERNAME=admin",
  "SPLUNKPASSWORD=$AdminPass",
  "/quiet", "/norestart",
  "/log", "$LogDir\splunk-uf-msi.log"
)
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
  err "msiexec exited with code $($proc.ExitCode) - see logs/splunk-uf-msi.log"
  Stop-Transcript; exit 1
}
ok "Splunk Universal Forwarder installed"

Start-Sleep -Seconds 10
$ufSvc = Get-Service -Name "SplunkForwarder" -ErrorAction SilentlyContinue
if ($ufSvc -and $ufSvc.Status -eq "Running") { ok "SplunkForwarder service: $($ufSvc.Status)" }
else { err "SplunkForwarder service: $($ufSvc.Status)" }

# -- 4. PowerShell + Sysmon + Defender + DNS + Transcription + Firewall --------
# The MSI's WINEVENTLOG_*_ENABLE properties only cover Application/Security/
# System - PowerShell/Operational (4103/4104, winserver-baseline.ps1),
# Sysmon/Operational (winserver-baseline.ps1), Windows Defender/Operational
# (winserver-defender-telemetry.ps1), and both DNS channels
# (winserver-dns-telemetry.ps1 enables DNS-Server/Analytical - it's off by
# default - and bumps DNS-Client/Operational's size) all need their own
# inputs.conf stanza - MiniLab-1f7, MiniLab-1d0, MiniLab-qju. PowerShell
# Transcription (winserver-powershell-transcription.ps1) and Windows
# Firewall logging (winserver-firewall-logging.ps1) are both file-based,
# not event channels, so they're monitor:// stanzas instead of
# WinEventLog:// - MiniLab-w5t, MiniLab-nub.
$SplunkHome = "C:\Program Files\SplunkUniversalForwarder"
$InputsConf = "$SplunkHome\etc\system\local\inputs.conf"
New-Item -ItemType Directory -Force -Path "$SplunkHome\etc\system\local" | Out-Null
Add-Content -Path $InputsConf -Value @"

[WinEventLog://Microsoft-Windows-PowerShell/Operational]
disabled = 0
index = main

[WinEventLog://Microsoft-Windows-Sysmon/Operational]
disabled = 0
index = main

[WinEventLog://Microsoft-Windows-Windows Defender/Operational]
disabled = 0
index = main

[WinEventLog://Microsoft-Windows-DNS-Server/Analytical]
disabled = 0
index = main

[WinEventLog://Microsoft-Windows-DNS-Client/Operational]
disabled = 0
index = main

[monitor://C:\PSTranscripts\*.txt]
disabled = 0
index = main
sourcetype = powershell_transcript

[monitor://C:\Windows\System32\LogFiles\Firewall\pfirewall.log]
disabled = 0
index = main
sourcetype = ms:windows:firewall
"@
& "$SplunkHome\bin\splunk.exe" restart | Out-Null
ok "PowerShell + Sysmon + Defender + DNS + Transcription + Firewall inputs added, forwarder restarted"

# -- 5. Save credentials -----------------------------------------------------------
@"
# Splunk Universal Forwarder credentials - generated $(Get-Date)
Username : admin
Password : $AdminPass
Indexer  : ${SIEM_IP}:9997
"@ | Out-File -FilePath "$LogDir\winserver-splunk-uf-credentials.txt" -Encoding ascii
ok "Credentials saved to logs/winserver-splunk-uf-credentials.txt"

# -- 6. Summary ----------------------------------------------------------------
log "=========================================================="
log "  WinServer Splunk Universal Forwarder setup COMPLETED"
log "  Forwarding to: ${SIEM_IP}:9997"
log "  Full log:      logs/winserver-splunk-forwarder.log"
log "=========================================================="

Stop-Transcript
