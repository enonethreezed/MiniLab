# Provisioning Windows Server 2022 - Advanced Audit Policy
# SOC Blue Team Lab. Requires winserver-baseline.ps1 to have run first.
#
# Windows ships with a much narrower audit policy than what detection
# engineering needs (e.g. no Process Creation/4688 command-line auditing by
# default). Enables success+failure auditing at the *category* level, which
# covers every specific subcategory TELEMETRY.md #1/#7 calls out without
# having to enumerate each one:
#   - Account Logon      -> covers Kerberos Authentication Service +
#                            Kerberos Service Ticket Operations
#   - Detailed Tracking   -> covers Process Creation (4688, with command
#                            line if paired with the registry key below)
#   - DS Access           -> covers Directory Service Access + Directory
#                            Service Changes (winserver only, since it's
#                            the DC - harmless no-op on a non-DC host)
#   - Account Management, Logon/Logoff, Object Access, Policy Change,
#     Privilege Use
#
# All of it lands in the Security channel, already collected by all 3
# SIEMs (ELK via the default Fleet windows integration, Splunk via
# WINEVENTLOG_SEC_ENABLE=1, Wazuh via the default ossec.conf Security
# localfile stanza) - no SIEM-side change needed for this one.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-audit-policy.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }
function err { param($m); Write-Host "$(ts) [ERR]     $m" }

log "=========================================================="
log "  WinServer audit policy setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

# -- 1. Category-level success+failure auditing --------------------------------
$categories = @(
  "Account Logon",
  "Account Management",
  "Detailed Tracking",
  "DS Access",
  "Logon/Logoff",
  "Object Access",
  "Policy Change",
  "Privilege Use"
)

foreach ($cat in $categories) {
  auditpol /set /category:"$cat" /success:enable /failure:enable | Out-Null
  if ($LASTEXITCODE -eq 0) { ok "Category enabled: $cat" }
  else { err "Failed to enable category: $cat (exit $LASTEXITCODE)" }
}

# -- 2. Command-line auditing on 4688 -------------------------------------------
# Process Creation (Detailed Tracking, above) logs 4688 but not the command
# line by default - this registry key is the other half of that.
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
  -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord
ok "4688 command-line auditing enabled"

# -- 3. Summary ----------------------------------------------------------------
log "--- Current audit policy ---"
auditpol /get /category:* | Out-String | Write-Host
log "=========================================================="
log "  WinServer audit policy setup COMPLETED"
log "  Full log: logs/winserver-audit-policy.log"
log "=========================================================="

Stop-Transcript
