## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:DCUScanOnly               - "1" to scan but not apply updates (default: "0")
## $env:LibTag                    - jsDelivr tag for shared libs (default: "release")

$ScriptLogName = "dell-command-update-run.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:DCUScanOnly)) { $env:DCUScanOnly = "0" }
if ([string]::IsNullOrEmpty($env:LibTag))      { $env:LibTag      = "release" }

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
        $env:Description = "Dell Command Update Run"
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

if (-not (Test-DCUInstalled)) {
    Write-Host "Dell Command Update is not installed. Run dell-command-update-install.ps1 first."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

$dcu = Get-DCUCliPath
Write-Host "DCU CLI: $dcu (version $(Get-DCUVersion))"

# Reference: https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-cli-commands
# Exit codes for /applyUpdates:
#   0 = success, 1 = reboot required, 2 = unknown error, 3 = not a Dell system,
#   4 = not admin, 5 = reboot pending, 6 = another instance running,
#   7 = unsupported model, 8 = no update filters configured.

Write-Host "`n--- dcu-cli /scan ---"
$scan = Start-Process -FilePath $dcu -ArgumentList "/scan" -Wait -PassThru -NoNewWindow
$scanExit = $scan.ExitCode
Write-Host "Scan exit code: $scanExit"

if ($env:DCUScanOnly -eq "1") {
    Write-Host "DCUScanOnly is set. Skipping applyUpdates."
    if ($TranscriptStarted) { Stop-Transcript }
    exit $scanExit
}

Write-Host "`n--- dcu-cli /applyUpdates ---"
$apply = Start-Process -FilePath $dcu -ArgumentList "/applyUpdates -autoSuspendBitLocker=enable -reboot=disable" -Wait -PassThru -NoNewWindow
$applyExit = $apply.ExitCode
Write-Host "Apply exit code: $applyExit"

switch ($applyExit) {
    0 { Write-Host "Updates applied successfully." }
    1 { Write-Host "Updates applied; reboot required to complete." }
    2 { Write-Host "Unknown application error." }
    3 { Write-Host "Not a Dell system. (Should not reach here ... Test-DellHardware passed.)" }
    4 { Write-Host "DCU CLI was not launched with administrative privilege." }
    5 { Write-Host "A reboot was pending from a previous operation." }
    6 { Write-Host "Another instance of DCU is already running." }
    7 { Write-Host "DCU does not support the current system model." }
    8 { Write-Host "No update filters have been applied or configured." }
    default { Write-Host "Unrecognized exit code: $applyExit" }
}

if ($TranscriptStarted) { Stop-Transcript }
exit $applyExit
