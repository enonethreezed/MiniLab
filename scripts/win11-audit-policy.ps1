# Provisioning Windows 11 (workstation) - Advanced Audit Policy
# SOC Blue Team Lab. Requires win11-baseline.ps1 to have run first.
#
# Same reasoning as winserver-audit-policy.ps1 - see that script's header
# for the category-to-subcategory mapping. DS Access is included too even
# though win11 isn't a DC - harmless no-op, kept for consistency between
# the two endpoints' policy.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\win11-audit-policy.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN11] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]    $m" }
function err { param($m); Write-Host "$(ts) [ERR]   $m" }

log "=========================================================="
log "  Win11 audit policy setup started"
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
New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
  -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1 -Type DWord
ok "4688 command-line auditing enabled"

# -- 3. Summary ----------------------------------------------------------------
log "--- Current audit policy ---"
auditpol /get /category:* | Out-String | Write-Host
log "=========================================================="
log "  Win11 audit policy setup COMPLETED"
log "  Full log: logs/win11-audit-policy.log"
log "=========================================================="

Stop-Transcript
