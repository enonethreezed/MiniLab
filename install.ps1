# MiniLab installer wrapper - sets the right ENABLE_* env vars and runs
# `vagrant up` (or `vagrant destroy -f`), so you don't have to remember the
# flag names. Also wraps the lifecycle commands (start/stop/suspend/resume)
# for an already-created environment, with a fixed VM order.
#
# Usage:
#   .\install.ps1 [-Siem splunk|wazuh] [-Guacamole] [-Velociraptor] [-KaliMinimal] [-Debug] [<vagrant up args>]
#   .\install.ps1 -Destroy [<vagrant destroy args>]
#   .\install.ps1 -Start|-Stop|-Suspend|-Resume|-Reload
#   .\install.ps1 -Status
#
# Examples:
#   .\install.ps1                              # ELK (default), no extras
#   .\install.ps1 -Siem splunk -Guacamole      # Splunk + Guacamole
#   .\install.ps1 -Velociraptor                # ELK + Velociraptor hunting console
#   .\install.ps1 -KaliMinimal kali            # stripped-down Kali attacker box only
#   .\install.ps1 -Debug                       # verbose Vagrant/provisioner output (VAGRANT_LOG=debug)
#   .\install.ps1 -Destroy                     # vagrant destroy -f (all VMs)
#   .\install.ps1 -Destroy win11                # vagrant destroy -f win11 only
#   .\install.ps1 siem                         # bring up siem only
#   .\install.ps1 -Siem splunk siem            # siem only, with Splunk
#   .\install.ps1 winserver                    # bring up winserver (DC) only
#   .\install.ps1 -Stop                        # halt win11, then winserver, then siem
#   .\install.ps1 -Start                       # up siem, then winserver, then win11
#   .\install.ps1 -Reload                      # reload siem, then winserver, then win11

[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet("splunk", "wazuh", "elk", "")]
  [string]$Siem = "",
  [switch]$Guacamole,
  [switch]$Velociraptor,
  [switch]$KaliMinimal,
  [switch]$Destroy,
  [switch]$Start,
  [switch]$Stop,
  [switch]$Suspend,
  [switch]$Resume,
  [switch]$Reload,
  [switch]$Status,
  [Alias("h")]
  [switch]$Help,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$VagrantArgs = @()
)

$ErrorActionPreference = "Stop"

function Show-Usage {
  @'
Usage: .\install.ps1 [-Siem splunk|wazuh] [-Guacamole] [-Velociraptor] [-KaliMinimal] [-Debug] [<vagrant up args>]
       .\install.ps1 -Destroy [<vagrant destroy args>]
       .\install.ps1 -Start|-Stop|-Suspend|-Resume|-Reload|-Status

  -Siem splunk|wazuh    Use Splunk or Wazuh instead of the default ELK stack
                        (mutually exclusive with each other)
  -Guacamole            Enable the Guacamole RDP/SSH gateway on siem
  -Velociraptor         Enable the Velociraptor hunting console on siem +
                        clients on winserver/win11 (not mutually exclusive
                        with -Siem - additive alongside any SIEM stack)
  -KaliMinimal          Bring up the Kali attacker box (implies ENABLE_KALI),
                        stripped to kali-linux-core after boot - the box
                        download is still the full kalilinux/rolling image
                        (no smaller official box exists), but the desktop
                        environment and default tool metapackage are purged
                        since this VM runs headless
  -Debug                Sets VAGRANT_LOG=debug before running vagrant -
                        verbose internal Vagrant/provisioner output, useful
                        when a provisioner fails and the plain log isn't
                        enough. This is PowerShell's own built-in common
                        parameter (comes free from CmdletBinding, not
                        declared here) - applies to every action below,
                        not just bringing the lab up. Also transcribes the
                        whole session to logs\debug.log, overwritten fresh
                        each run.
  -Destroy              Run `vagrant destroy -f` instead of `vagrant up`
                        (ignores -Siem/-Guacamole/-Velociraptor, which only
                        matter when bringing the lab up)
  -Start                Boot an already-created environment: siem, then
                        winserver, then win11 (kali last, if defined)
  -Stop                 Halt an already-created environment: win11, then
                        winserver, then siem (kali first, if defined)
  -Suspend              Same order as -Stop, but suspend instead of halt
  -Resume               Same order as -Start, but resume instead of up
  -Reload               Same order as -Start, but reload (restart +
                        re-run provisioners) instead of up
  -Status               Run `vagrant status`
  -Help, -h             Show this help

Anything not matching a named parameter above is passed straight through to
`vagrant up` / `vagrant destroy`. Not applicable to -Start/-Stop/-Suspend/
-Resume/-Reload/-Status, which always act on every VM currently defined in
the Vagrantfile (respecting whatever ENABLE_KALI was set to when the
environment was created).

Examples:
  .\install.ps1 siem                     # bring up siem only
  .\install.ps1 -Siem splunk siem        # siem only, with Splunk
  .\install.ps1 winserver                # bring up winserver (DC) only
  .\install.ps1 -Destroy win11           # destroy win11 only
'@
}

if ($Help) {
  Show-Usage
  exit 0
}

# $env: assignments persist for the whole PowerShell session, not just this
# script - clear all three first so a previous invocation's flags in the same
# window can't leak into this one (e.g. -Siem splunk once, then a bare
# re-run later expecting ELK).
Remove-Item Env:ENABLE_SPLUNK          -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_WAZUH           -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_GUACAMOLE       -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_VELOCIRAPTOR    -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_KALI            -ErrorAction SilentlyContinue
Remove-Item Env:ENABLE_KALI_MINIMAL    -ErrorAction SilentlyContinue
Remove-Item Env:VAGRANT_LOG            -ErrorAction SilentlyContinue

# -Debug is PowerShell's own common parameter (free from CmdletBinding) -
# declaring our own [switch]$Debug would collide with it, so it's read via
# $PSBoundParameters instead.
if ($PSBoundParameters.ContainsKey('Debug')) {
  $env:VAGRANT_LOG = "debug"
  # Full session (this wrapper's own output + Vagrant's verbose output)
  # captured to logs\debug.log, overwritten fresh each run - not appended,
  # so it always reflects only the most recent attempt. Still prints live
  # to the console too (Start-Transcript doesn't suppress it), this isn't
  # a silent redirect.
  try { Stop-Transcript | Out-Null } catch {}
  New-Item -ItemType Directory -Force -Path "logs" | Out-Null
  Start-Transcript -Path "logs\debug.log" -Force | Out-Null
  Write-Host "Debug mode: full output also being saved to logs\debug.log"
}

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
if ($Guacamole)    { $env:ENABLE_GUACAMOLE = "true" }
if ($Velociraptor) { $env:ENABLE_VELOCIRAPTOR = "true" }
if ($KaliMinimal)  { $env:ENABLE_KALI = "true"; $env:ENABLE_KALI_MINIMAL = "true" }

$summary = @()
if ($env:ENABLE_SPLUNK -eq "true")       { $summary += "ENABLE_SPLUNK=true" }
if ($env:ENABLE_WAZUH -eq "true")        { $summary += "ENABLE_WAZUH=true" }
if ($env:ENABLE_GUACAMOLE -eq "true")    { $summary += "ENABLE_GUACAMOLE=true" }
if ($env:ENABLE_VELOCIRAPTOR -eq "true") { $summary += "ENABLE_VELOCIRAPTOR=true" }
if ($env:ENABLE_KALI -eq "true")         { $summary += "ENABLE_KALI=true" }
if ($env:ENABLE_KALI_MINIMAL -eq "true") { $summary += "ENABLE_KALI_MINIMAL=true" }
if ($env:VAGRANT_LOG)                    { $summary += "VAGRANT_LOG=$($env:VAGRANT_LOG)" }

Write-Host "Running: $($summary -join ' ') vagrant up $($VagrantArgs -join ' ')"
vagrant up @VagrantArgs
