# MiniLab health check — Windows
# Verifies the SIEM (ELK by default, Splunk with ENABLE_SPLUNK=true, or
# Wazuh with ENABLE_WAZUH=true) and that agents (siem itself, winserver,
# win11) have enrolled and integrated with the Fleet console. In Splunk/
# Wazuh mode there is no PowerShell-side check yet (see tests/check-splunk.sh
# / tests/check-wazuh.sh) — this script just confirms local host services
# when run on winserver/win11.
#
# Run this either on the Vagrant host (Windows), or directly on winserver /
# win11 (it will also check the local Elastic Agent / Sysmon services when
# run there). Uses Windows PowerShell 5.1-compatible syntax (no
# -SkipCertificateCheck / -Authentication, since Kibana is plain HTTP here).

param(
  [string]$SiemIp           = "192.168.56.10",
  [string]$KibanaUrl        = "http://${SiemIp}:5601",
  [string]$EsUrl            = "http://${SiemIp}:9200",
  [string]$FleetUrl         = "http://${SiemIp}:8220",
  [string]$CredentialsFile  = "C:\vagrant\logs\credentials.txt",
  [string[]]$ExpectedHosts  = @("siem", "WIN-SRV22", "WIN11-WS01"),
  [string]$EnableSplunk     = $env:ENABLE_SPLUNK,
  [string]$EnableWazuh      = $env:ENABLE_WAZUH
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$script:PassCount = 0
$script:FailCount = 0

function Write-Pass { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green; $script:PassCount++ }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:FailCount++ }
function Write-Section { param($m) Write-Host ""; Write-Host "== $m ==" }

if ($EnableSplunk -eq "true") {
  Write-Section "SIEM: Splunk (ENABLE_SPLUNK=true)"
  Write-Host "  [SKIP] No PowerShell-side Splunk check yet - run tests/check-splunk.sh from a Linux/macOS host"
} elseif ($EnableWazuh -eq "true") {
  Write-Section "SIEM: Wazuh (ENABLE_WAZUH=true)"
  Write-Host "  [SKIP] No PowerShell-side Wazuh check yet - run tests/check-wazuh.sh from a Linux/macOS host"
} else {

if (-not (Test-Path $CredentialsFile)) {
  Write-Host "Cannot find credentials file at $CredentialsFile"
  Write-Host "Pass -CredentialsFile <path> or run this after 'vagrant up siem'."
  exit 2
}

$credLine = (Get-Content $CredentialsFile | Select-String "Password    : ").ToString()
$ElasticPass = $credLine -replace "^Password    : ", ""
if ([string]::IsNullOrWhiteSpace($ElasticPass)) {
  Write-Host "Could not extract elastic password from $CredentialsFile"
  exit 2
}

$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("elastic:${ElasticPass}"))
$headers = @{ "Authorization" = $authHeader; "kbn-xsrf" = "true" }

function Invoke-Api {
  param([string]$Uri)
  try {
    return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -TimeoutSec 10
  } catch {
    return $null
  }
}

Write-Section "Elasticsearch ($EsUrl)"
$esHealth = Invoke-Api "$EsUrl/_cluster/health"
if ($esHealth -and ($esHealth.status -eq "green" -or $esHealth.status -eq "yellow")) {
  Write-Pass "Elasticsearch reachable, cluster health: $($esHealth.status)"
} elseif ($esHealth) {
  Write-Fail "Elasticsearch reachable but cluster health: '$($esHealth.status)'"
} else {
  Write-Fail "Elasticsearch not reachable at $EsUrl"
}

Write-Section "Kibana ($KibanaUrl)"
$kibanaStatus = Invoke-Api "$KibanaUrl/api/status"
if ($kibanaStatus -and $kibanaStatus.status.overall.level -eq "available") {
  Write-Pass "Kibana available"
} elseif ($kibanaStatus) {
  Write-Fail "Kibana status: '$($kibanaStatus.status.overall.level)'"
} else {
  Write-Fail "Kibana not reachable at $KibanaUrl"
}

Write-Section "Fleet Server ($FleetUrl)"
try {
  $fleetStatus = Invoke-RestMethod -Uri "$FleetUrl/api/status" -Method Get -TimeoutSec 10
  if ($fleetStatus -and $fleetStatus.name) {
    Write-Pass "Fleet Server reachable ($($fleetStatus.name))"
  } else {
    Write-Fail "Fleet Server reachable but returned unexpected response"
  }
} catch {
  Write-Fail "Fleet Server not reachable at $FleetUrl"
}

Write-Section "Fleet agent enrollment (Kibana console)"
$agentsResp = Invoke-Api "$KibanaUrl/api/fleet/agents"
if (-not $agentsResp) {
  Write-Fail "Could not query Fleet agents API"
} else {
  # A lab that's been destroyed/recreated repeatedly can have multiple stale
  # agent records for the same hostname; keep only the most recent per host.
  $latest = @{}
  foreach ($a in $agentsResp.items) {
    $host_ = $a.local_metadata.host.hostname
    if (-not $host_) { $host_ = $a.id }
    if (-not $latest.ContainsKey($host_) -or $a.enrolled_at -gt $latest[$host_].enrolled_at) {
      $latest[$host_] = @{ status = $a.status; enrolled_at = $a.enrolled_at }
    }
  }

  if ($latest.Count -eq 0) {
    Write-Fail "No agents enrolled in Fleet yet"
  } else {
    foreach ($expected in $ExpectedHosts) {
      $match = $latest.Keys | Where-Object { $_ -ieq $expected }
      if (-not $match) {
        Write-Fail "Agent '$expected' not found in Fleet"
        continue
      }
      $agentStatus = $latest[$match].status
      if ($agentStatus -eq "online") {
        Write-Pass "Agent '$expected' enrolled, status: online"
      } else {
        Write-Fail "Agent '$expected' enrolled but status: $agentStatus"
      }
    }
  }
}

Write-Section "Windows Endpoints integrations"
$policiesResp = Invoke-Api "$KibanaUrl/api/fleet/agent_policies"
$policyId = $null
if ($policiesResp) {
  $policy = $policiesResp.items | Where-Object { $_.name -eq "Windows Endpoints" }
  if ($policy) { $policyId = $policy.id }
}

if (-not $policyId) {
  Write-Fail "'Windows Endpoints' agent policy not found"
} else {
  $packagesResp = Invoke-Api "$KibanaUrl/api/fleet/package_policies"
  $packages = @()
  if ($packagesResp) {
    $packages = $packagesResp.items | Where-Object { $_.policy_id -eq $policyId } | ForEach-Object { $_.package.name }
  }
  foreach ($pkg in @("system", "windows")) {
    if ($packages -contains $pkg) {
      Write-Pass "Integration '$pkg' present on 'Windows Endpoints'"
    } else {
      Write-Fail "Integration '$pkg' missing from 'Windows Endpoints'"
    }
  }
}

}  # EnableSplunk

Write-Section "Local host services (this machine only)"
if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
  Write-Host "  [SKIP] Get-Service not available on this platform (not Windows)"
} else {
  foreach ($svcName in @("Elastic Agent", "Sysmon64")) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
      Write-Host "  [SKIP] Service '$svcName' not present on this machine"
    } elseif ($svc.Status -eq "Running") {
      Write-Pass "Local service '$svcName' running"
    } else {
      Write-Fail "Local service '$svcName' status: $($svc.Status)"
    }
  }
}

Write-Section "Summary"
Write-Host "  Passed: $script:PassCount   Failed: $script:FailCount"
if ($script:FailCount -gt 0) {
  Write-Host "  Lab is NOT fully healthy." -ForegroundColor Yellow
  exit 1
} else {
  Write-Host "  Lab is healthy." -ForegroundColor Green
  exit 0
}
