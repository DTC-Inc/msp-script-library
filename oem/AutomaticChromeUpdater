#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes Google Chrome and reinstalls the latest version.

.DESCRIPTION
    Production deployment script for Google Chrome that:
    - Detects if Chrome is currently installed (registry + file system)
    - Gracefully closes running Chrome processes
    - Uninstalls the existing version silently
    - Downloads the latest Chrome Enterprise MSI from Google
    - Performs a silent installation
    - Validates the new installation

.PARAMETER ForceReinstall
    Reinstall Chrome even if the latest version is already installed.

.PARAMETER SkipUninstall
    Skip the uninstall step (fresh install only).

.PARAMETER DownloadOnly
    Only download the installer without running installation.

.PARAMETER LogPath
    Path for log file. Default: $env:TEMP\ChromeReinstall.log

.EXAMPLE
    .\Reinstall-Chrome.ps1
    Detect, uninstall, and reinstall Chrome with the latest version.

.EXAMPLE
    .\Reinstall-Chrome.ps1 -ForceReinstall
    Force reinstall even if Chrome appears up to date.

.EXAMPLE
    .\Reinstall-Chrome.ps1 -SkipUninstall
    Install Chrome without uninstalling first (repair/overlay install).

.NOTES
    Version:        1.0.0
    Requirements:   PowerShell 5.1+, Administrator rights, Internet connectivity
    Installer:      Google Chrome Enterprise 64-bit MSI (always latest from Google)
#>

[CmdletBinding()]
param(
    [switch]$ForceReinstall,
    [switch]$SkipUninstall,
    [switch]$DownloadOnly,
    [string]$LogPath = "$env:TEMP\ChromeReinstall.log"
)

#region Configuration
$Script:Config = @{
    # Google's stable URL — always returns the latest Chrome Enterprise 64-bit MSI
    DownloadUrl  = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
    InstallerDir = "$env:TEMP\ChromeReinstall"
    InstallerMsi = "googlechromestandaloneenterprise64.msi"

    # Known Chrome install locations
    ChromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
}
#endregion

#region Logging
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    $prefix = switch ($Level) {
        'Info'    { "[*]" }
        'Warning' { "[!]" }
        'Error'   { "[X]" }
        'Success' { "[+]" }
    }

    Write-Host "$timestamp $prefix $Message" -ForegroundColor $color
    Add-Content -Path $LogPath -Value "$timestamp $prefix $Message" -ErrorAction SilentlyContinue
}
#endregion

#region Detection
function Get-ChromeInstallInfo {
    <#
    .SYNOPSIS
        Detects installed Chrome from registry uninstall entries.
        Returns install info or $null if not found.
    #>

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $uninstallPaths) {
        $chrome = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Google Chrome*" } |
            Select-Object -First 1

        if ($chrome) {
            return [PSCustomObject]@{
                DisplayName    = $chrome.DisplayName
                DisplayVersion = $chrome.DisplayVersion
                UninstallString = $chrome.UninstallString
                QuietUninstall  = $chrome.QuietUninstallString
                InstallLocation = $chrome.InstallLocation
            }
        }
    }

    return $null
}

function Get-ChromeExePath {
    <#
    .SYNOPSIS
        Returns the path to chrome.exe if found on disk.
    #>

    foreach ($path in $Script:Config.ChromePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    return $null
}
#endregion

#region Uninstall
function Stop-ChromeProcesses {
    <#
    .SYNOPSIS
        Gracefully closes Chrome, then force-kills if still running.
    #>

    $chromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue

    if (-not $chromeProcs) {
        Write-Log "No running Chrome processes found" -Level Info
        return
    }

    Write-Log "Found $($chromeProcs.Count) Chrome process(es) — closing gracefully..." -Level Warning

    # Try graceful close first
    $chromeProcs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 3

    # Force-kill any remaining
    $remaining = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Log "Force-stopping $($remaining.Count) remaining Chrome process(es)" -Level Warning
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Log "All Chrome processes stopped" -Level Success
}

function Uninstall-Chrome {
    param([PSCustomObject]$InstallInfo)

    Write-Log "Uninstalling Chrome $($InstallInfo.DisplayVersion)..." -Level Info

    # Build the uninstall command
    # Chrome's uninstall string typically contains setup.exe with flags
    $uninstallCmd = $InstallInfo.UninstallString

    if (-not $uninstallCmd) {
        Write-Log "No uninstall string found in registry" -Level Error
        return $false
    }

    # Try MSI uninstall first if the uninstall string references msiexec
    if ($uninstallCmd -match "MsiExec") {
        # Extract the product code
        if ($uninstallCmd -match "\{[A-F0-9\-]+\}") {
            $productCode = $matches[0]
            Write-Log "Uninstalling via MSI product code: $productCode" -Level Info
            $process = Start-Process -FilePath "msiexec.exe" `
                -ArgumentList "/x `"$productCode`" /qn /norestart" `
                -Wait -PassThru -NoNewWindow
        }
        else {
            Write-Log "Could not extract MSI product code from: $uninstallCmd" -Level Error
            return $false
        }
    }
    else {
        # EXE-based uninstall (typical for consumer Chrome installs)
        # Chrome setup.exe accepts --uninstall --force-uninstall --system-level
        if ($uninstallCmd -match '^"?(.+\.exe)"?\s*(.*)$') {
            $exePath = $matches[1].Trim('"')
            $existingArgs = $matches[2]
        }
        else {
            $exePath = $uninstallCmd
            $existingArgs = ""
        }

        $silentArgs = "$existingArgs --force-uninstall --system-level"
        Write-Log "Uninstalling via: `"$exePath`" $silentArgs" -Level Info
        $process = Start-Process -FilePath $exePath -ArgumentList $silentArgs `
            -Wait -PassThru -NoNewWindow
    }

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 19 -or $process.ExitCode -eq 3010) {
        Write-Log "Chrome uninstalled successfully (exit code: $($process.ExitCode))" -Level Success
        return $true
    }
    else {
        Write-Log "Uninstall returned exit code: $($process.ExitCode)" -Level Warning
        # Check if Chrome is actually gone
        Start-Sleep -Seconds 2
        $stillInstalled = Get-ChromeInstallInfo
        if (-not $stillInstalled) {
            Write-Log "Chrome removed despite non-zero exit code" -Level Success
            return $true
        }
        Write-Log "Chrome still appears to be installed after uninstall attempt" -Level Error
        return $false
    }
}
#endregion

#region Install
function Get-ChromeInstaller {
    <#
    .SYNOPSIS
        Downloads the latest Chrome Enterprise MSI from Google.
    #>

    $url = $Script:Config.DownloadUrl
    $outDir = $Script:Config.InstallerDir
    $outFile = Join-Path $outDir $Script:Config.InstallerMsi

    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    # Remove any previous download
    if (Test-Path $outFile) {
        Remove-Item -Path $outFile -Force
    }

    Write-Log "Downloading latest Chrome Enterprise MSI..." -Level Info
    Write-Log "URL: $url" -Level Info

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec 300

        $fileSize = (Get-Item $outFile).Length
        if ($fileSize -lt 1MB) {
            Write-Log "Downloaded file is suspiciously small ($([math]::Round($fileSize/1KB, 0)) KB) — download may have failed" -Level Error
            return $null
        }

        Write-Log "Download complete ($([math]::Round($fileSize/1MB, 1)) MB)" -Level Success
        return $outFile
    }
    catch {
        Write-Log "Download failed: $_" -Level Error
        return $null
    }
}

function Install-Chrome {
    param([string]$MsiPath)

    Write-Log "Installing Chrome from $MsiPath..." -Level Info

    $arguments = "/i `"$MsiPath`" /qn /norestart"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments `
        -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "Chrome installed successfully (exit code: $($process.ExitCode))" -Level Success
        return $true
    }
    else {
        Write-Log "Chrome installation failed with exit code: $($process.ExitCode)" -Level Error
        return $false
    }
}
#endregion

#region Validation
function Test-ChromeInstallation {
    <#
    .SYNOPSIS
        Validates that Chrome is installed and reports the version.
    #>

    Write-Host "`n=== Validating Installation ===" -ForegroundColor Cyan

    $info = Get-ChromeInstallInfo
    $exePath = Get-ChromeExePath

    $checks = @()

    # Registry check
    if ($info) {
        $checks += @{ Component = "Registry entry"; Status = "PASS"; Detail = "$($info.DisplayName) $($info.DisplayVersion)" }
    }
    else {
        $checks += @{ Component = "Registry entry"; Status = "FAIL"; Detail = "Not found" }
    }

    # File check
    if ($exePath) {
        $fileVersion = (Get-Item $exePath).VersionInfo.FileVersion
        $checks += @{ Component = "chrome.exe"; Status = "PASS"; Detail = "$exePath (v$fileVersion)" }
    }
    else {
        $checks += @{ Component = "chrome.exe"; Status = "FAIL"; Detail = "Not found in expected locations" }
    }

    # Output results
    $allPassed = $true
    foreach ($check in $checks) {
        $color = switch ($check.Status) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
        }
        Write-Host "  [$($check.Status)] $($check.Component): $($check.Detail)" -ForegroundColor $color
        if ($check.Status -eq 'FAIL') { $allPassed = $false }
    }

    return $allPassed
}
#endregion

#region Main
$ErrorActionPreference = 'Stop'

Write-Host @"

=====================================================
       Chrome Reinstall Script v1.0.0
       Detect / Uninstall / Install Latest
=====================================================

"@ -ForegroundColor Cyan

try {
    # Enable TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- Step 1: Detect existing Chrome ---
    Write-Host "=== Detecting Chrome ===" -ForegroundColor Cyan
    $existingChrome = Get-ChromeInstallInfo
    $chromeExe = Get-ChromeExePath

    if ($existingChrome) {
        Write-Log "Chrome detected: $($existingChrome.DisplayName) v$($existingChrome.DisplayVersion)" -Level Info
    }
    elseif ($chromeExe) {
        $fileVer = (Get-Item $chromeExe).VersionInfo.FileVersion
        Write-Log "Chrome binary found at $chromeExe (v$fileVer) but no registry entry" -Level Warning
    }
    else {
        Write-Log "Chrome is NOT currently installed" -Level Info
    }

    # --- Step 2: Uninstall (if present and not skipped) ---
    if ($existingChrome -and -not $SkipUninstall) {
        Write-Host "`n=== Uninstalling Chrome ===" -ForegroundColor Cyan

        Stop-ChromeProcesses

        $uninstallOk = Uninstall-Chrome -InstallInfo $existingChrome
        if (-not $uninstallOk) {
            Write-Log "Uninstall failed — aborting to prevent conflicts" -Level Error
            exit 1
        }

        # Brief pause for uninstaller cleanup
        Start-Sleep -Seconds 3
    }
    elseif ($SkipUninstall) {
        Write-Log "Skipping uninstall (SkipUninstall flag set)" -Level Info
    }

    # --- Step 3: Download latest Chrome ---
    Write-Host "`n=== Downloading Chrome ===" -ForegroundColor Cyan

    $msiPath = Get-ChromeInstaller
    if (-not $msiPath) {
        Write-Log "Failed to download Chrome installer — aborting" -Level Error
        exit 1
    }

    if ($DownloadOnly) {
        Write-Log "Download-only mode — installer saved to $msiPath" -Level Info
        exit 0
    }

    # --- Step 4: Install Chrome ---
    Write-Host "`n=== Installing Chrome ===" -ForegroundColor Cyan

    $installOk = Install-Chrome -MsiPath $msiPath
    if (-not $installOk) {
        Write-Log "Installation failed" -Level Error
        exit 1
    }

    # --- Step 5: Validate ---
    $valid = Test-ChromeInstallation

    Write-Host ""
    if ($valid) {
        Write-Host "=====================================================" -ForegroundColor Green
        Write-Host "  CHROME REINSTALLED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "=====================================================" -ForegroundColor Green
    }
    else {
        Write-Host "=====================================================" -ForegroundColor Yellow
        Write-Host "  COMPLETED WITH WARNINGS — Review validation above" -ForegroundColor Yellow
        Write-Host "=====================================================" -ForegroundColor Yellow
    }

    # Cleanup installer
    if (Test-Path $msiPath) {
        Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up installer" -Level Info
    }

    Write-Host "`n  Log file: $LogPath" -ForegroundColor Gray
    Write-Host ""

    if ($valid) { exit 0 } else { exit 2 }
}
catch {
    Write-Log "Unhandled exception: $_" -Level Error
    Write-Log $_.ScriptStackTrace -Level Error
    exit 1
}
#endregion
