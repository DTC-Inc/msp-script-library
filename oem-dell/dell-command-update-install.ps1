## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:DCUTargetVersion          - Minimum acceptable DCU version (default: "5.7.0")
## $env:DCUInstallerURL           - Override Dell-hosted installer URL (default: see below)
## $env:DCUInstallerSha256        - SHA256 of the installer EXE (TODO: capture and pin)
## $env:LibTag                    - jsDelivr tag for shared libs (default: "release")

$ScriptLogName = "dell-command-update-install.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:DCUTargetVersion)) { $env:DCUTargetVersion = "5.7.0" }
# TODO: Confirm the canonical Dell-hosted EXE URL for DCU 5.7 Classic (driver ID RXT5N)
# from https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update and pin it.
if ([string]::IsNullOrEmpty($env:DCUInstallerURL)) {
    $env:DCUInstallerURL = "https://dl.dell.com/FOLDER/RXT5N/Dell-Command-Update-Application_RXT5N_WIN_5.7.0_A00.EXE"
}
# TODO: Capture SHA256 of the installer once the canonical URL is confirmed.
if ([string]::IsNullOrEmpty($env:DCUInstallerSha256)) {
    $env:DCUInstallerSha256 = "REPLACE_WITH_REAL_HASH"
}
if ([string]::IsNullOrEmpty($env:LibTag)) { $env:LibTag = "release" }

# === LIB BOOTSTRAP ===
# TODO: Replace REPLACE_WITH_REAL_HASH once libs land on @release.

$libs = @(
    @{ Url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-shared/lib/oem-manufacturer-detect.ps1"
       Sha256 = "REPLACE_WITH_REAL_HASH" },
    @{ Url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-dell/lib/dell-detection.ps1"
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
        $env:Description = "Dell Command Update Install"
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

if (-not (Test-DellHardware)) {
    Write-Host "Not a Dell endpoint. Exiting."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$targetVersion = [version]$env:DCUTargetVersion
$installedVersion = Get-DCUVersion

if ($installedVersion -ne $null -and $installedVersion -ge $targetVersion) {
    Write-Host "DCU $installedVersion already meets target $targetVersion. Skipping install."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

Write-Host "DCU installed: $installedVersion. Target: $targetVersion. Installing."

$installerPath = Join-Path $env:TEMP "dell-command-update-installer.exe"
try {
    Get-VerifiedDownload -Url $env:DCUInstallerURL -OutFile $installerPath -Sha256 $env:DCUInstallerSha256 | Out-Null
} catch {
    Write-Host "Failed to download DCU installer: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

Write-Host "Running silent install: $installerPath /s"
$proc = Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait -PassThru -NoNewWindow
Write-Host "Installer exit code: $($proc.ExitCode)"

Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

$postVersion = Get-DCUVersion
if ($postVersion -ne $null -and $postVersion -ge $targetVersion) {
    Write-Host "DCU $postVersion installed successfully."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
} else {
    Write-Host "DCU install verification failed. Installed version: $postVersion"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}
