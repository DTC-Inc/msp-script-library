## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:LSUTargetVersion          - Minimum acceptable LSU version (default: "5.08.03.59")
## $env:LSUInstallerURL           - Override Lenovo-hosted installer URL (default: see below)
## $env:LSUInstallerSha256        - SHA256 of the installer EXE (TODO: capture and pin)
##
## NOTE: This script installs Lenovo System Update (LSU), the public driver/BIOS/firmware
## lifecycle tool that does not require Lenovo Partner Hub enrollment. If DTC enrolls in
## Partner Hub, a preferred alternative is Lenovo Commercial Vantage (no ads, integrates
## with the same LSU update pipeline). Gate the swap on $env:LenovoVantageCommercialAvailable
## from the baseline orchestrator. TODO: implement Commercial Vantage install path.

$ScriptLogName = "lenovo-system-update-install.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:LSUTargetVersion)) { $env:LSUTargetVersion = "5.08.03.59" }
# TODO: Confirm the direct Lenovo CDN download URL for LSU 5.08.03.59 from
# https://support.lenovo.com/us/en/downloads/ds012808 and pin it. The download.lenovo.com URL
# is timestamped; capture the exact URL the support page resolves to.
if ([string]::IsNullOrEmpty($env:LSUInstallerURL)) {
    $env:LSUInstallerURL = "https://download.lenovo.com/pccbbs/thinkvantage_en/system_update_5.08.03.59.exe"
}
# TODO: Capture SHA256 of system_update_5.08.03.59.exe once the canonical URL is confirmed.
if ([string]::IsNullOrEmpty($env:LSUInstallerSha256)) {
    $env:LSUInstallerSha256 = "REPLACE_WITH_REAL_HASH"
}

# === LIB BOOTSTRAP ===
# Libs are pinned to a commit SHA in the jsDelivr URL. jsDelivr serves
# immutable content per SHA, so the URL itself is the integrity check.
# TODO: bump SHA when oem-shared/lib or oem-lenovo/lib changes.
$libBaseUrl = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@5b1b16c4b19816343145138941c3c5fa51a095e8"
$libs = @(
    "$libBaseUrl/oem-shared/lib/oem-manufacturer-detect.ps1",
    "$libBaseUrl/oem-lenovo/lib/lenovo-detection.ps1"
)
foreach ($url in $libs) {
    $libPath = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($url))
    Invoke-WebRequest -Uri $url -OutFile $libPath -UseBasicParsing -ErrorAction Stop
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
        $env:Description = "Lenovo System Update Install"
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

if (-not (Test-LenovoHardware)) {
    Write-Host "Not a Lenovo endpoint. Exiting."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$targetVersion = [version]$env:LSUTargetVersion
$installedVersion = Get-LSUVersion

if ($installedVersion -ne $null -and $installedVersion -ge $targetVersion) {
    Write-Host "LSU $installedVersion already meets target $targetVersion. Skipping install."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

Write-Host "LSU installed: $installedVersion. Target: $targetVersion. Installing."

$installerPath = Join-Path $env:TEMP "lenovo-system-update-installer.exe"
try {
    Get-VerifiedDownload -Url $env:LSUInstallerURL -OutFile $installerPath -Sha256 $env:LSUInstallerSha256 | Out-Null
} catch {
    Write-Host "Failed to download LSU installer: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

# LSU uses an Inno Setup installer. /verysilent suppresses UI; /norestart leaves
# reboot decisions to the RMM. Reference: Lenovo CDRT LSU deployment guide.
Write-Host "Running silent install: $installerPath /verysilent /norestart"
$proc = Start-Process -FilePath $installerPath -ArgumentList "/verysilent","/norestart" -Wait -PassThru -NoNewWindow
Write-Host "Installer exit code: $($proc.ExitCode)"

Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

$postVersion = Get-LSUVersion
if ($postVersion -ne $null -and $postVersion -ge $targetVersion) {
    Write-Host "LSU $postVersion installed successfully."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
} else {
    Write-Host "LSU install verification failed. Installed version: $postVersion"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}
