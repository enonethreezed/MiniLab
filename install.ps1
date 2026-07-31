# MiniLab installer wrapper - sets the right ENABLE_* env vars and runs
# `vagrant up` (or `vagrant destroy -f`), so you don't have to remember the
# flag names. Also wraps the lifecycle commands (start/stop/suspend/resume)
# for an already-created environment, with a fixed VM order.
#
# Usage:
#   .\install.ps1 [-Siem splunk|wazuh] [-Guacamole] [<vagrant up args>]
#   .\install.ps1 -Destroy [<vagrant destroy args>]
#   .\install.ps1 -Start|-Stop|-Suspend|-Resume|-Reload
#   .\install.ps1 -Status
#
# Examples:
#   .\install.ps1                              # ELK (default), no extras
#   .\install.ps1 -Siem splunk -Guacamole      # Splunk + Guacamole
#   .\install.ps1 -Destroy                     # vagrant destroy -f (all VMs)
#   .\install.ps1 -Destroy win11                # vagrant destroy -f win11 only
#   .\install.ps1 -Stop                        # halt win11, then winserver, then siem
#   .\install.ps1 -Start                       # up siem, then winserver, then win11
#   .\install.ps1 -Reload                      # reload siem, then winserver, then win11

[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet("splunk", "wazuh", "elk", "")]
  [string]$Siem = "",
  [switch]$Guacamole,
  [switch]$Destroy,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Suspend,
  [switch]$Resume,
  [switch]$Reload,
  [switch]$Status,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$VagrantArgs = @()
)

$ErrorActionPreference = "Stop"

# $env: assignments persist for the whole PowerShell session, not just this
# script - clear all three first so a previous invocation's flags in the same
# window can't leak into this one (e.g. -Siem splunk once, then a bare
# re-run later expecting ELK).
Remove-Item Env:ENABLE_SPLUNK    -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_WAZUH     -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_GUACAMOLE -ErrorAction SilentlyContinue

if ($Destroy) {
  Write-Host "Running: vagrant destroy -f $($VagrantArgs -join ' ')"
  vagrant destroy -f @VagrantArgs
  exit $LASTEXITCODE
}

if ($Status) {
  vagrant status
  exit $LASTEXITCODE
}

if ($Start -or $Stop -or $Suspend -or $Resume -or $Reload) {
  # Machines actually defined right now (respects ENABLE_KALI at call time),
  # in Vagrantfile declaration order.
  $lines = vagrant status --machine-readable 2>$null
  $defined = @()
  foreach ($line in $lines) {
    $parts = $line -split ','
    if ($parts.Count -ge 4 -and $parts[2] -eq 'metadata' -and $parts[3] -eq 'provider') {
      $defined += $parts[1]
    }
  }
  $upOrder = @("siem", "winserver", "win11", "kali") | Where-Object { $defined -contains $_ }
  $downOrder = @($upOrder)
  [array]::Reverse($downOrder)

  function Invoke-InOrder {
    param([string]$Cmd, [string[]]$Vms)
    $failed = $false
    foreach ($vm in $Vms) {
      Write-Host "==> vagrant $Cmd $vm"
      vagrant $Cmd $vm
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "'vagrant $Cmd $vm' failed"
        $failed = $true
      }
    }
    if ($failed) { exit 1 } else { exit 0 }
  }

  if ($Start)   { Invoke-InOrder -Cmd "up" -Vms $upOrder }
  if ($Resume)  { Invoke-InOrder -Cmd "resume" -Vms $upOrder }
  if ($Reload)  { Invoke-InOrder -Cmd "reload" -Vms $upOrder }
  if ($Stop)    { Invoke-InOrder -Cmd "halt" -Vms $downOrder }
  if ($Suspend) { Invoke-InOrder -Cmd "suspend" -Vms $downOrder }
}

switch ($Siem) {
  "splunk" { $env:ENABLE_SPLUNK = "true" }
  "wazuh"  { $env:ENABLE_WAZUH  = "true" }
}
if ($Guacamole) { $env:ENABLE_GUACAMOLE = "true" }

$summary = @()
if ($env:ENABLE_SPLUNK -eq "true")    { $summary += "ENABLE_SPLUNK=true" }
if ($env:ENABLE_WAZUH -eq "true")     { $summary += "ENABLE_WAZUH=true" }
if ($env:ENABLE_GUACAMOLE -eq "true") { $summary += "ENABLE_GUACAMOLE=true" }

Write-Host "Running: $($summary -join ' ') vagrant up $($VagrantArgs -join ' ')"
vagrant up @VagrantArgs
