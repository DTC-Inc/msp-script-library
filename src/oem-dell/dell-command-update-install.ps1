## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:DCUTargetVersion          - Minimum acceptable DCU version (default: "5.7.0")
## $env:DCUInstallerURL           - Override the Dell-hosted installer URL (see TODO below)

# %INCLUDE src/lib/oem-manufacturer-detect.ps1
# %INCLUDE src/lib/dell-detection.ps1

$ScriptLogName = "dell-command-update-install.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:DCUTargetVersion)) { $env:DCUTargetVersion = "5.7.0" }

# TODO: Confirm the canonical Dell-hosted EXE URL for DCU 5.7 Classic from
# https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update and
# pin it here. The placeholder below points at Dell's published download path
# pattern but the specific folder ID needs to be captured from a fresh
# manual download against the published KB so we know we're tracking the
# Dell-supported build.
if ([string]::IsNullOrEmpty($env:DCUInstallerURL)) {
    $env:DCUInstallerURL = "https://dl.dell.com/FOLDER/Dell-Command-Update-Application_WIN_5.7.0_A00.EXE"
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

# Internet check ... only the install step needs vendor download connectivity.
# dell-command-update-run / dell-configure / dell-debloat do NOT include this
# because they operate on already-installed tooling and should still work on
# an endpoint that's offline at the moment.
function Test-InternetAvailable {
    try {
        $resp = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

if (-not (Test-InternetAvailable)) {
    Write-Host "No internet connectivity detected ... skipping DCU install. If DCU is already installed, dell-command-update-run will still work. Exit 0."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$targetVersion = [version]$env:DCUTargetVersion
$installedVersion = Get-DCUVersion

if ($null -ne $installedVersion -and $installedVersion -ge $targetVersion) {
    Write-Host "DCU $installedVersion already meets target $targetVersion. Skipping install."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

Write-Host "DCU installed: $installedVersion. Target: $targetVersion. Installing."

$installerPath = Join-Path $env:TEMP "dell-command-update-installer.exe"
try {
    Invoke-WebRequest -Uri $env:DCUInstallerURL -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Host "Failed to download DCU installer from $env:DCUInstallerURL : $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

Write-Host "Running silent install: $installerPath /s"
$proc = Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait -PassThru -NoNewWindow
Write-Host "Installer exit code: $($proc.ExitCode)"

Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

$postVersion = Get-DCUVersion
if ($null -ne $postVersion -and $postVersion -ge $targetVersion) {
    Write-Host "DCU $postVersion installed successfully."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
} else {
    Write-Host "DCU install verification failed. Installed version: $postVersion"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}
