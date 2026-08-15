# Provisioning Windows Server 2022 - DNS telemetry
# SOC Blue Team Lab. Requires winserver-baseline.ps1 and ad-domain-setup.ps1
# to have run first (the DC promotion installs the DNS Server role via
# -InstallDns:$true).
#
# winserver only - it's the AD DC and DNS server; win11 has no DNS Server
# role to log from (its DNS-Client/Operational channel is enabled by
# default already, nothing to do there).

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-dns-telemetry.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }
function err { param($m); Write-Host "$(ts) [ERR]     $m" }

log "=========================================================="
log "  WinServer DNS telemetry setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

# -- 1. Confirm the DNS Server role is present ---------------------------------
$dnsRole = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
if ($dnsRole -and $dnsRole.Installed) {
  ok "DNS Server role: installed"
} else {
  err "DNS Server role not found - expected from ad-domain-setup.ps1 (-InstallDns:\$true)"
}

# -- 2. Enable DNS-Server/Analytical --------------------------------------------
# Analytic channels are disabled by default in Windows and drop every event
# until explicitly enabled - unlike the Operational channels used elsewhere
# in this lab (PowerShell, Sysmon, Defender), which log out of the box.
wevtutil sl "Microsoft-Windows-DNS-Server/Analytical" /e:true /ms:104857600
ok "DNS-Server/Analytical enabled, channel size bumped to 100MB"

# -- 3. Room for DNS-Client/Operational -----------------------------------------
# Enabled by default already - just bump the size like the other channels.
wevtutil sl "Microsoft-Windows-DNS-Client/Operational" /ms:104857600
ok "DNS-Client/Operational channel size bumped to 100MB"

# -- 4. Summary ----------------------------------------------------------------
log "=========================================================="
log "  WinServer DNS telemetry setup COMPLETED"
log "  Full log: logs/winserver-dns-telemetry.log"
log "=========================================================="

Stop-Transcript
