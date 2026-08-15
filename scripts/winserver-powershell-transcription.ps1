# Provisioning Windows Server 2022 - PowerShell Transcription
# SOC Blue Team Lab. Requires winserver-baseline.ps1 to have run first.
#
# Different collection mechanism from Script Block/Module Logging (done in
# winserver-baseline.ps1): those write to the Microsoft-Windows-PowerShell/
# Operational event channel, this writes plain-text .txt transcripts to a
# directory on disk - no eventchannel agent picks it up, needs a dedicated
# file-monitoring input per SIEM (see winserver-splunk-forwarder.ps1 /
# winserver-wazuh-agent.ps1 / elk-provision.sh).

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$TranscriptDir = "C:\PSTranscripts"

# -- Logging -------------------------------------------------------------------
$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\winserver-powershell-transcription.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

function ts  { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
function log { param($m); Write-Host "$(ts) [WIN-SRV] $m" }
function ok  { param($m); Write-Host "$(ts) [OK]      $m" }

log "=========================================================="
log "  WinServer PowerShell Transcription setup started"
log "  Log: $LogFile (synced to Vagrant host)"
log "=========================================================="

New-Item -ItemType Directory -Force -Path $TranscriptDir | Out-Null
ok "Transcript directory: $TranscriptDir"

$transPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
New-Item -Path $transPath -Force | Out-Null
Set-ItemProperty -Path $transPath -Name "EnableTranscripting" -Value 1 -Type DWord
Set-ItemProperty -Path $transPath -Name "EnableInvocationHeader" -Value 1 -Type DWord
Set-ItemProperty -Path $transPath -Name "OutputDirectory" -Value $TranscriptDir -Type String
ok "PowerShell Transcription enabled"

log "=========================================================="
log "  WinServer PowerShell Transcription setup COMPLETED"
log "  Full log: logs/winserver-powershell-transcription.log"
log "=========================================================="

Stop-Transcript
