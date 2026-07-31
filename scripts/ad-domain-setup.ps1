# Promote winserver to the first Domain Controller of a new forest: minilab.local
# SOC Blue Team Lab
#
# Runs as the local Administrator account (Vagrant's WinRM identity for this
# VM). After Install-ADDSForest completes and the machine reboots, the local
# SAM database is replaced by the domain database - the built-in
# Administrator account (RID 500) becomes the domain Administrator, keeping
# the same password, and stays a Domain Admin automatically. No separate
# credential bootstrap is needed.

param(
  [string]$DomainName = "minilab.local"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\ad-domain-setup.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [AD-DC] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  AD DS forest setup started  |  Domain: $DomainName"
log "=========================================================="

# Idempotency: skip entirely if this box is already a domain controller
$domainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
# DomainRole: 4 = Backup DC, 5 = Primary DC
if ($domainRole -ge 4) {
  $existingDomain = (Get-CimInstance Win32_ComputerSystem).Domain
  ok "Already a domain controller for $existingDomain - nothing to do"
  Stop-Transcript
  exit 0
}

log "Installing AD-Domain-Services role..."
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
ok "AD-Domain-Services installed"

# DSRM (Directory Services Restore Mode) is a separate, rarely-used recovery
# credential distinct from day-to-day Administrator/vagrant WinRM auth - it
# must meet Windows' password complexity requirements (upper+lower+digit+
# symbol), which the lab's simple "vagrant" password fails outright.
$SafeModePass = ConvertTo-SecureString "V4grant!2026" -AsPlainText -Force
$NetbiosName  = $DomainName.Split('.')[0].ToUpper()

log "Promoting to first Domain Controller of a new forest: $DomainName (NetBIOS: $NetbiosName)..."
Install-ADDSForest `
  -DomainName $DomainName `
  -DomainNetbiosName $NetbiosName `
  -SafeModeAdministratorPassword $SafeModePass `
  -InstallDns:$true `
  -NoRebootOnCompletion:$true `
  -Force:$true `
  -Confirm:$false

ok "AD DS forest created - reboot required to activate domain services"
log "=========================================================="
log "  AD DS forest setup COMPLETED (pending reboot)"
log "=========================================================="

Stop-Transcript
