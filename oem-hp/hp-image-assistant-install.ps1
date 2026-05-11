## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:HPIATargetVersion         - Minimum acceptable HPIA version (default: "5.3.4")
## $env:HPIAInstallerURL          - Override HP-hosted installer URL (default: see below)
## $env:HPIAInstallerSha256       - SHA256 of the installer EXE (TODO: capture and pin)
## $env:LibTag                    - jsDelivr tag for shared libs (default: "release")

$ScriptLogName = "hp-image-assistant-install.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:HPIATargetVersion)) { $env:HPIATargetVersion = "5.3.4" }
# TODO: Confirm the canonical HP-hosted EXE URL for HPIA 5.3.4 from
# https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html and pin it.
if ([string]::IsNullOrEmpty($env:HPIAInstallerURL)) {
    $env:HPIAInstallerURL = "https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.4.exe"
}
# TODO: Capture SHA256 of the installer once the canonical URL is confirmed.
if ([string]::IsNullOrEmpty($env:HPIAInstallerSha256)) {
    $env:HPIAInstallerSha256 = "REPLACE_WITH_REAL_HASH"
}
if ([string]::IsNullOrEmpty($env:LibTag)) { $env:LibTag = "release" }

# === LIB BOOTSTRAP ===
# TODO: Replace REPLACE_WITH_REAL_HASH once libs land on @release.

$libs = @(
    @{ Url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-shared/lib/oem-manufacturer-detect.ps1"
       Sha256 = "REPLACE_WITH_REAL_HASH" },
    @{ Url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-hp/lib/hp-detection.ps1"
       Sha256 = "REPLACE_WITH_REAL_HASH" }
)
foreach ($lib in $libs) {
    $libPath = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($lib.Url))
    Invoke-WebRequest -Uri $lib.Url -OutFile $libPath -UseBasicParsing -ErrorAction Stop
    $actual = (Get-FileHash -Path $libPath -Algorithm SHA256).Hash
    if ($actual -ne $lib.Sha256) {
        throw "Lib SHA256 mismatch for $($lib.Url). Expected $($lib.Sha256), got $actual."
    }
    . $libPath
}

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }
    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "HP Image Assistant Install"
    }
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

$TranscriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop
    $TranscriptStarted = $true
} catch {
    Write-Host "Warning: Could not start transcript logging to $LogPath - $($_.Exception.Message)"
}

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"

if (-not (Test-HPHardware)) {
    Write-Host "Not an HP endpoint. Exiting."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$targetVersion = [version]$env:HPIATargetVersion
$installedVersion = Get-HPIAVersion

if ($null -ne $installedVersion -and $installedVersion -ge $targetVersion) {
    Write-Host "HPIA $installedVersion already meets target $targetVersion. Skipping install."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

Write-Host "HPIA installed: $installedVersion. Target: $targetVersion. Installing."

$installerPath = Join-Path $env:TEMP "hp-image-assistant-installer.exe"
try {
    Get-VerifiedDownload -Url $env:HPIAInstallerURL -OutFile $installerPath -Sha256 $env:HPIAInstallerSha256 | Out-Null
} catch {
    Write-Host "Failed to download HPIA installer: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

Write-Host "Running silent install: $installerPath /s"
$proc = Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait -PassThru -NoNewWindow
Write-Host "Installer exit code: $($proc.ExitCode)"

Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

$postVersion = Get-HPIAVersion
if ($null -ne $postVersion -and $postVersion -ge $targetVersion) {
    Write-Host "HPIA $postVersion installed successfully."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
} else {
    Write-Host "HPIA install verification failed. Installed version: $postVersion"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}
