# This script installs the tools I use.
# I'm sharing it here in case it's useful to someone.
# It's not documented because everyone uses their own tools.
# It takes over an hour to install everything. 

$LogDir  = "C:\vagrant\logs"
$LogFile = "$LogDir\install-dfir.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path $LogFile -Append -Force

Write-Output "`nStarting Tools Provisioning"

function Safe-RemoveItem($path) {
    if (!(Test-Path $path)) { return }
    Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.IsReadOnly = $false } catch {} }
    $maxRetries = 5; $retry = 0
    do {
        try { Remove-Item -Recurse -Force $path -ErrorAction Stop; return }
        catch { $retry++; Start-Sleep -Milliseconds 500 }
    } while ($retry -lt $maxRetries)
}

function Test-TemurinMSI {
    $key   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $found = Get-ChildItem $key | ForEach-Object { Get-ItemProperty $_.PSPath } |
             Where-Object { $_.DisplayName -match 'Temurin.*21' }
    return $found -ne $null
}

function Test-Winget {
    try { winget --version | Out-Null; return $true }
    catch  { return $false }
}

function Repair-WingetSources {
    # Works around winget error 0x8a15005e ("The server certificate did not
    # match any of the expected values") against the msstore source, which
    # otherwise fails every single install regardless of target source -
    # common in VM/lab environments. Documented winget workaround.
    winget settings --enable BypassCertificatePinningForMicrosoftStore | Out-Null

    Write-Output "Resetting winget sources to defaults..."
    winget source reset --force
    winget source update

    if ($LASTEXITCODE -eq 0) { return }

    Write-Warning "winget source reset/update failed. Recreating default sources..."
    winget source remove winget
    winget source remove msstore
    winget source add --name winget --arg https://cdn.winget.microsoft.com/cache --type Microsoft.PreIndexed.Package
    winget source add --name msstore --arg https://storeedgefd.dsx.mp.microsoft.com/v9.0 --type Microsoft.Rest
    winget source update

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to repair winget sources."
    }
}

function Test-WingetPackageInstalled($pkgId) {
    $listOutput = winget list --id $pkgId --exact --accept-source-agreements 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    return [bool]($listOutput | Select-String -SimpleMatch $pkgId)
}

function Install-WingetPackage($pkgId) {
    Write-Output "=> Verifying $pkgId..."

    if (Test-WingetPackageInstalled $pkgId) {
        Write-Output "   $pkgId already installed"
        return
    }

    Write-Output "   Not installed. Installing $pkgId..."
    winget install --id $pkgId --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install $pkgId failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-WingetPackageInstalled $pkgId)) {
        throw "winget reported success for $pkgId, but the package is still not listed as installed."
    }

    Write-Output "   Installed $pkgId"
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
}

function Add-GitToSessionPath {
    Update-SessionPath

    if (Get-Command git -ErrorAction SilentlyContinue) { return $true }

    $gitPaths = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LocalAppData)) {
        if (-not $root) { continue }
        if ($root -eq $env:LocalAppData) {
            $gitPaths += Join-Path $root 'Programs\Git\cmd'
            $gitPaths += Join-Path $root 'Programs\Git\bin'
        }
        else {
            $gitPaths += Join-Path $root 'Git\cmd'
            $gitPaths += Join-Path $root 'Git\bin'
        }
    }
    $gitPaths = $gitPaths | Where-Object { Test-Path (Join-Path $_ 'git.exe') }

    foreach ($gitPath in $gitPaths) {
        if ($env:Path -notlike "*$gitPath*") {
            $env:Path = "$env:Path;$gitPath"
        }
    }

    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Install-GitForWindows {
    Write-Warning "Installing Git from Git for Windows release because winget did not provide git.exe."

    $repoGit    = 'git-for-windows/git'
    $releaseGit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoGit/releases/latest" -Headers $headers
    $assetGit   = $releaseGit.assets |
        Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } |
        Select-Object -First 1

    if (-not $assetGit) {
        throw "Unable to find the latest Git for Windows installer."
    }

    $gitInstaller = Join-Path $downloadsFolder $assetGit.name
    if (!(Test-Path $gitInstaller)) {
        Invoke-WebRequest -Uri $assetGit.browser_download_url -OutFile $gitInstaller -Headers $headers
    }

    Start-Process $gitInstaller -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait

    $gitCmd = Join-Path $env:ProgramFiles 'Git\cmd'
    if (Test-Path (Join-Path $gitCmd 'git.exe')) {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath -notlike "*$gitCmd*") {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$gitCmd", 'Machine')
        }
    }
}


# Base paths
$desktop            = [Environment]::GetFolderPath('Desktop')
$baseFolder         = Join-Path $desktop 'tools'
$reversingFolder    = Join-Path $baseFolder 'reversing'
$downloadsFolder    = Join-Path $baseFolder 'downloads'
$ghidraInstallLog   = Join-Path $downloadsFolder 'ghidra_installed.log'
$radareFolder       = Join-Path $reversingFolder 'radare2'
$ghidraFolder       = Join-Path $reversingFolder 'ghidra'
$pebearFolder       = Join-Path $reversingFolder 'pe-bear'
$x64dbgFolder       = Join-Path $reversingFolder 'x64dbg'
$sysinternalsFolder = Join-Path $baseFolder 'SysInternals'

Write-Output "Creating required directories..."
foreach ($folder in @(
    $baseFolder, $reversingFolder, $downloadsFolder,
    $radareFolder, $ghidraFolder, $pebearFolder, $x64dbgFolder
)) {
    if (!(Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

Write-Output "Initializing Ghidra installation log..."
if (!(Test-Path $ghidraInstallLog)) {
    New-Item -ItemType File -Path $ghidraInstallLog -Force | Out-Null
}
$installedGhidraZips = Get-Content $ghidraInstallLog | ForEach-Object { $_.Trim() }

$headers = @{ 'User-Agent' = 'Mozilla/5.0' }

Write-Output "Configuring Defender exclusions..."
Add-MpPreference -ExclusionPath "c:\vagrant"

# - Radare2 -
Write-Output "Downloading and installing Radare2..."
$repoR2    = 'radareorg/radare2'
$releaseR2 = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoR2/releases/latest" -Headers $headers
$assetR2   = $releaseR2.assets | Where-Object { $_.name -like '*w64.zip' } | Select-Object -First 1

if ($assetR2) {
    $zipDownload = Join-Path $downloadsFolder $assetR2.name
    if (!(Test-Path $zipDownload)) {
        Invoke-WebRequest -Uri $assetR2.browser_download_url -OutFile $zipDownload -Headers $headers
    }
    $tempExtract = Join-Path $env:TEMP 'radare2_temp'
    Safe-RemoveItem $tempExtract
    Expand-Archive -Path $zipDownload -DestinationPath $tempExtract -Force

    $binFile     = 'r2blob.static.exe'
    $newBinPath  = Get-ChildItem -Path $tempExtract -Recurse -Filter $binFile | Select-Object -First 1

    if ($newBinPath) {
        $newHash     = Get-FileHash $newBinPath.FullName -Algorithm SHA256
        $existingBin = Get-ChildItem -Path $radareFolder -Recurse -Filter $binFile | Select-Object -First 1
        $needUpdate  = $true

        if ($existingBin) {
            $existingHash = Get-FileHash $existingBin.FullName -Algorithm SHA256
            if ($existingHash.Hash -eq $newHash.Hash) {
                $needUpdate = $false
            }
        }

        if ($needUpdate) {
            Safe-RemoveItem $radareFolder
            New-Item -ItemType Directory -Path $radareFolder -Force | Out-Null
            Expand-Archive -Path $zipDownload -DestinationPath $radareFolder -Force
        }
    }

    Safe-RemoveItem $tempExtract
}

# - Ghidra: download latest release -
Write-Output "Downloading latest Ghidra release..."
$repoGhidra    = 'NationalSecurityAgency/ghidra'
$releaseGhidra = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoGhidra/releases/latest" -Headers $headers
$assetGhidra   = $releaseGhidra.assets | Where-Object { $_.name -like 'ghidra_*.zip' } | Select-Object -First 1

if ($assetGhidra) {
    $zipGhidra = Join-Path $downloadsFolder $assetGhidra.name
    if (!(Test-Path $zipGhidra)) {
        Write-Output "=> Downloading Ghidra $($assetGhidra.name)..."
        Invoke-WebRequest -Uri $assetGhidra.browser_download_url -OutFile $zipGhidra -Headers $headers
    }
}

# - Ghidra: processing downloaded packages -
Write-Output "Processing Ghidra packages..."
$ghidraZips = Get-ChildItem -Path $downloadsFolder -Filter 'ghidra_*.zip' | Sort-Object Name -Descending
foreach ($zip in $ghidraZips) {
    if ($zip.Name -match 'ghidra_([\d\.]+)_') {
        if ($installedGhidraZips -contains $zip.Name) { continue }
        Expand-Archive -Path $zip.FullName -DestinationPath $ghidraFolder -Force
        Add-Content -Path $ghidraInstallLog -Value $zip.Name
    }
}

# - Temurin JDK 21 -
Write-Output "Installing Temurin JDK 21..."
$msiUrl   = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.3%2B9/OpenJDK21U-jdk_x64_windows_hotspot_21.0.3_9.msi'
$msiName  = 'OpenJDK21U-jdk_x64_windows_hotspot_21.0.3_9.msi'
$msiPath  = Join-Path $downloadsFolder $msiName

if (!(Test-Path $msiPath)) {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -Headers $headers
}
if (-not (Test-TemurinMSI)) {
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
}

$jdkRoot = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory |
           Where-Object { $_.Name -like 'jdk-21*' } |
           Select-Object -First 1

if ($jdkRoot) {
    $jdkBin      = Join-Path $jdkRoot.FullName 'bin'
    $currentPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($currentPath -notlike "*$jdkBin*") {
        [Environment]::SetEnvironmentVariable('Path', "$currentPath;$jdkBin", 'User')
    }
}

# - Winget installs with detailed log -
Write-Output "Installing packages via winget..."
if (Test-Winget) {
    Repair-WingetSources

    $packages = @(
        'Sandboxie.Classic',
        'WinsiderSS.SystemInformer',
        'Python.Python.3.13',
        'Git.Git',
        'UPX.UPX',
        'WireGuard.WireGuard',
        'VPNetwork.TorGuard',
        'Microsoft.VisualStudioCode'
    )
    $wingetFailures = @()
    foreach ($pkgId in $packages) {
        try {
            Install-WingetPackage $pkgId
        }
        catch {
            if ($_.Exception.Message -match 'No package found') {
                Write-Warning "   Package not found: $pkgId"
            }
            else {
                Write-Warning "   Error installing $pkgId : $($_.Exception.Message)"
            }
            $wingetFailures += $pkgId
        }
    }

    if ($wingetFailures.Count -gt 0) {
        # Non-fatal: a single incompatible/unavailable winget package (e.g.
        # Microsoft Store licensing quirks in a non-interactive VM) should
        # not abort the rest of the toolset install (PE-Bear, Visual Studio,
        # x64dbg, Sysinternals, Win11Debloat all come after this block).
        Write-Warning "winget failed to install or verify: $($wingetFailures -join ', ')"
    }
}
else {
    Write-Warning "winget not available; skipping package installs."
}

# - PE-Bear -
Write-Output "Downloading PE-Bear..."
$repoPEBear      = 'hasherezade/pe-bear'
$releasePEBear   = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoPEBear/releases/latest" -Headers $headers
$assetPEBear = $releasePEBear.assets | Where-Object { $_.name -match '^pe-bear.*\.zip$' } | Select-Object -First 1

if ($assetPEBear) {
    $zipDownloadPEBear = Join-Path $downloadsFolder $assetPEBear.name
    if (!(Test-Path $zipDownloadPEBear)) {
        Invoke-WebRequest -Uri $assetPEBear.browser_download_url -OutFile $zipDownloadPEBear -Headers $headers
        Expand-Archive -Path $zipDownloadPEBear -DestinationPath $pebearFolder -Force
    }
}

# - Visual Studio Community -
Write-Output "Installing Visual Studio Community..."
$vsInstaller = Join-Path $downloadsFolder 'vs_Community.exe'
if (!(Test-Path $vsInstaller)) {
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_Community.exe' -OutFile $vsInstaller -Headers $headers
}
$vsInstalled = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^\d{4}$' }
if (-not $vsInstalled) {
    Start-Process $vsInstaller -ArgumentList `
        '--add Microsoft.VisualStudio.Workload.NativeDesktop',
        '--add Microsoft.VisualStudio.Workload.ManagedDesktop',
        '--quiet','--wait','--norestart','--nocache','--noUpdateInstaller' -Wait
}

# - x64dbg -
Write-Output "Downloading and installing x64dbg..."
$repoX64dbg    = 'x64dbg/x64dbg'
$releaseX64dbg = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoX64dbg/releases/latest" -Headers $headers
$assetX64dbg = $releaseX64dbg.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1

if ($assetX64dbg) {
    $x64dbgZip = Join-Path $downloadsFolder $assetX64dbg.name
    if (!(Test-Path $x64dbgZip)) {
        Invoke-WebRequest -Uri $assetX64dbg.browser_download_url -OutFile $x64dbgZip -Headers $headers
        Expand-Archive -Path $x64dbgZip -DestinationPath $x64dbgFolder -Force
    }
}

# - Sysinternals -
Write-Output "Downloading Sysinternals Suite..."
$sysinternalsUrl = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
$sysinternalsZip = Join-Path $downloadsFolder 'SysinternalsSuite.zip'

if (!(Test-Path $sysinternalsZip)) {
    Invoke-WebRequest -Uri $sysinternalsUrl -OutFile $sysinternalsZip -Headers $headers
}

if (!(Test-Path $sysinternalsFolder)) {
    Expand-Archive -Path $sysinternalsZip -DestinationPath $sysinternalsFolder -Force
}

# Ensure Git is available before invoking it. winget/MSI installers do not always refresh PATH in-session.
if (-not (Add-GitToSessionPath)) {
    if (Test-Winget) {
        Write-Warning "Git was not found after package installs. Trying winget once more..."
        winget install --id Git.Git --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    }
}

if (-not (Add-GitToSessionPath)) {
    Install-GitForWindows
}

if (-not (Add-GitToSessionPath)) {
    throw "Git installation completed but git.exe was not found in PATH or standard install locations. Restart PowerShell and rerun this script."
}

# - Clone or update Win11Debloat -
Write-Output "Preparing GitHub workspace..."
$githubBase = Join-Path $baseFolder 'github'
$repoName   = 'Win11Debloat'
$repoUrl    = 'https://github.com/Raphire/Win11Debloat.git'
$repoFolder = Join-Path $githubBase $repoName

if (!(Test-Path $githubBase)) {
    New-Item -ItemType Directory -Path $githubBase -Force | Out-Null
}

if (!(Test-Path $repoFolder)) {
    Write-Output "Cloning $repoName into tools\github..."
    git clone $repoUrl $repoFolder
}
else {
    if (Test-Path (Join-Path $repoFolder '.git')) {
        Write-Output "Repository already exists; updating $repoName..."
        Push-Location $repoFolder
        $pullOutput = git pull 2>&1
        if ($pullOutput -match 'Already up[ -]to[ -]date') {
            Write-Output "   $repoName is already up to date."
        }
        elseif ($LASTEXITCODE -eq 0) {
            Write-Output "   $repoName updated successfully."
        }
        else {
            Write-Warning "   Error updating $repoName : $pullOutput"
        }
        Pop-Location
    }
    else {
        Write-Output "Directory exists but isn't a git repository. Recloning $repoName..."
        Safe-RemoveItem $repoFolder
        git clone $repoUrl $repoFolder
    }
}

Write-Output "`nTools Provisioning COMPLETED"
Stop-Transcript






