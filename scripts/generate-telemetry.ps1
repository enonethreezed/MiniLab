# Deterministic telemetry generator - SOC Blue Team Lab
#
# Not a provisioner - run this manually, on-demand, against an already
# provisioned winserver or win11, to produce a predictable set of benign
# events and verify they actually reach the SIEM (pair with
# tests/check-telemetry.sh on the host side). This is not attack
# simulation - it's a "telemetry contract": each action below maps to a
# specific expected event, so a missing event means a broken collector,
# not a missed detection.
#
# Usage (from the Vagrant host):
#   vagrant winrm winserver -c 'C:\vagrant\scripts\generate-telemetry.ps1'
#   vagrant winrm win11     -c 'C:\vagrant\scripts\generate-telemetry.ps1'
#
# Every action cleans up after itself (test user/service/task/key/file
# all removed) - safe to re-run repeatedly.

param(
  # ValidateCredentials() needs a password known to be correct to also
  # generate a *successful* logon (4624), not just a failed one (4625).
  # Matches this lab's known default (Vagrantfile winrm.password for both
  # winserver's Administrator and win11's local vagrant account) - override
  # if you've changed it.
  [string]$KnownGoodPassword = "vagrant",
  [string]$SiemIP = "192.168.56.10"
)

$ErrorActionPreference = "Continue"

$Hostname = $env:COMPUTERNAME
$TestUser = "minilab-telemetry-test"
$TestGroup = "Users"
$TestDir = "C:\MiniLabTelemetryTest"
$TestRegKey = "HKLM:\SOFTWARE\MiniLabTelemetryTest"
$TestTaskName = "MiniLabTelemetryTest"
$TestServiceName = "MiniLabTelemetryTest"

function ts   { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log  { param($m); Write-Host "$(ts) [$Hostname] $m" }
function ok   { param($m, $evt); Write-Host "$(ts) [OK]  $m (expect: $evt)" -ForegroundColor Green }
function fail { param($m, $err); Write-Host "$(ts) [ERR] $m - $err" -ForegroundColor Red }

function run {
  param([string]$Name, [string]$ExpectedEvent, [scriptblock]$Action)
  try {
    & $Action | Out-Null
    ok $Name $ExpectedEvent
  } catch {
    fail $Name $_.Exception.Message
  }
}

log "=========================================================="
log "  MiniLab deterministic telemetry generator"
log "=========================================================="

Add-Type -AssemblyName System.DirectoryServices.AccountManagement
$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
  [System.DirectoryServices.AccountManagement.ContextType]::Machine)

run "Failed authentication" "4625 (Security)" {
  $ctx.ValidateCredentials((whoami), "definitely-wrong-$(Get-Random)")
}

run "Successful authentication" "4624 (Security)" {
  $ctx.ValidateCredentials((whoami).Split('\')[-1], $KnownGoodPassword)
}

run "Process creation" "4688 (Security) + Sysmon 1" {
  Start-Process -FilePath "cmd.exe" -ArgumentList "/c echo minilab-telemetry-test" -Wait -WindowStyle Hidden
}

run "PowerShell execution" "4103/4104 (PowerShell/Operational)" {
  Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -Command `"Write-Host 'minilab-telemetry-test'`"" `
    -Wait -WindowStyle Hidden
}

run "DNS query" "DNS-Client/Operational (+ DNS-Server/Analytical on winserver)" {
  Resolve-DnsName -Name "minilab.local" -ErrorAction SilentlyContinue | Out-Null
}

run "Network connection" "Sysmon 3 + Firewall log" {
  Test-NetConnection -ComputerName $SiemIP -Port 443 -WarningAction SilentlyContinue
}

run "File creation" "Sysmon 11 (+ 23 on cleanup)" {
  New-Item -ItemType Directory -Force -Path $TestDir | Out-Null
  "minilab-telemetry-test" | Out-File -FilePath "$TestDir\test.txt" -Encoding ascii
  Remove-Item -Path $TestDir -Recurse -Force
}

run "Registry modification" "Sysmon 12/13" {
  New-Item -Path $TestRegKey -Force | Out-Null
  Set-ItemProperty -Path $TestRegKey -Name "test" -Value "minilab" -Type String
  Remove-Item -Path $TestRegKey -Recurse -Force
}

run "Scheduled task creation" "4698 (Security) + Sysmon" {
  $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c exit"
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
  Register-ScheduledTask -TaskName $TestTaskName -Action $action -Trigger $trigger -Force | Out-Null
  Unregister-ScheduledTask -TaskName $TestTaskName -Confirm:$false
}

run "Service creation" "4697/7045 (Security/System) + Sysmon" {
  New-Service -Name $TestServiceName -BinaryPathName "C:\Windows\System32\cmd.exe" `
    -StartupType Manual -ErrorAction Stop | Out-Null
  Start-Sleep -Seconds 1
  Remove-Service -Name $TestServiceName -ErrorAction SilentlyContinue
}

run "Account creation" "4720 (Security)" {
  $pw = ConvertTo-SecureString "T3mp!" -AsPlainText -Force
  New-LocalUser -Name $TestUser -Password $pw -Description "minilab telemetry test - safe to delete" | Out-Null
}

run "Group membership modification" "4732 (Security)" {
  Add-LocalGroupMember -Group $TestGroup -Member $TestUser
  Start-Sleep -Seconds 1
  Remove-LocalGroupMember -Group $TestGroup -Member $TestUser
}

run "Account cleanup" "4726 (Security)" {
  Remove-LocalUser -Name $TestUser -ErrorAction Stop
}

log "=========================================================="
log "  Generator run COMPLETED"
log "  Verify on the host with: bash tests/check-telemetry.sh"
log "=========================================================="
