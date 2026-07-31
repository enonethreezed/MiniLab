# Join win11 to the minilab.local AD domain
# SOC Blue Team Lab
#
# win11 is a domain MEMBER, not a controller - its local 'vagrant' account is
# unaffected by joining the domain (only DC promotion replaces the local SAM).
# The join operation itself uses the domain Administrator account, which
# keeps the same password as winserver's local Administrator did before
# promotion.

param(
  [string]$WSRV_IP    = "192.168.56.20",
  [string]$DomainName = "minilab.local"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\domain-join.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [JOIN] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]   $m" }
function err { param($m); Write-Host "$(ts) [ERR]  $m" }

log "=========================================================="
log "  Domain join started  |  Domain: $DomainName  |  DC: $WSRV_IP"
log "=========================================================="

# Enable inbound SMB/NetBIOS so nmap/ldapsearch/nmblookup/smbclient can
# verify domain membership remotely from the Linux host - disabled by
# default on a fresh Windows 11 install.
log "Enabling File and Printer Sharing firewall rules (for remote SMB verification)..."
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Out-Null
ok "File and Printer Sharing firewall rules enabled"

# Idempotency: skip if already domain-joined
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -ieq $DomainName) {
  ok "Already joined to $DomainName - nothing to do"
  Stop-Transcript
  exit 0
}

# Point the private-network adapter's DNS at the new DC so minilab.local resolves
log "Setting DNS server for the private network adapter to $WSRV_IP..."
$adapter = Get-NetIPAddress -IPAddress "192.168.56.*" -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty InterfaceAlias
if (-not $adapter) {
  err "Could not find the 192.168.56.0/24 network adapter"
  Stop-Transcript; exit 1
}
Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $WSRV_IP
ok "DNS set on adapter '$adapter'"

log "Waiting for $DomainName to resolve (up to 5 min)..."
$resolved = $false
for ($i = 1; $i -le 20; $i++) {
  try {
    Resolve-DnsName -Name $DomainName -ErrorAction Stop | Out-Null
    $resolved = $true
    break
  } catch {
    log "  attempt $i/20 - waiting 15s..."
    Start-Sleep -Seconds 15
  }
}
if (-not $resolved) {
  err "Could not resolve $DomainName - is winserver's AD DS fully up?"
  Stop-Transcript; exit 1
}
ok "$DomainName resolves"

$domainCred = New-Object System.Management.Automation.PSCredential(
  "Administrator@$DomainName",
  (ConvertTo-SecureString "vagrant" -AsPlainText -Force)
)

log "Joining domain $DomainName ..."
Add-Computer -DomainName $DomainName -Credential $domainCred -Force
ok "Domain join command completed - reboot required"

log "=========================================================="
log "  Domain join COMPLETED (pending reboot)"
log "=========================================================="

Stop-Transcript
