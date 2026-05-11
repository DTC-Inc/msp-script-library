## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:LSUScanOnly               - "1" to scan but not apply updates (default: "0")

$ScriptLogName = "lenovo-system-update-run.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:LSUScanOnly)) { $env:LSUScanOnly = "0" }

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
        $env:Description = "Lenovo System Update Run"
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

if (-not (Test-LSUInstalled)) {
    Write-Host "Lenovo System Update is not installed. Run lenovo-system-update-install.ps1 first."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

$lsu = Get-LSUCliPath
Write-Host "LSU CLI: $lsu (version $(Get-LSUVersion))"

# Reference: https://docs.lenovocdrt.com/guides/sus/su_dg/su_dg_ch5/
# Tvsu.exe flags used:
#   /CM                           command-line mode (required)
#   -search A                     All updates (Critical + Recommended + Optional) ... mirrors DCU's applyUpdates breadth
#   -action LIST                  scan only (list available updates, no download/install)
#   -action INSTALL               download + install
#   -includerebootpackages 1,3,4  include reboot types 1 (normal), 3 (force-reboot), 4 (defer-reboot).
#                                 without this, BIOS and reboot-required firmware are skipped.
#   -noreboot                     never auto-reboot (RMM controls reboots)
#   -nolicense                    auto-accept EULAs
#   -noicon                       suppress system tray icon
#
# TODO: Tvsu.exe exit codes are thinly documented. Observed: 0 = success, non-zero = error.
# Post-run "what installed / what failed" is in %PROGRAMDATA%\Lenovo\SystemUpdate\session.xml.
# Capture real exit codes during endpoint testing and expand this mapping.

$commonArgs = @("/CM","-search","A","-includerebootpackages","1,3,4","-noreboot","-nolicense","-noicon")

if ($env:LSUScanOnly -eq "1") {
    Write-Host "`n--- Tvsu.exe -action LIST (scan only) ---"
    $scanArgs = $commonArgs + @("-action","LIST")
    $scan = Start-Process -FilePath $lsu -ArgumentList $scanArgs -Wait -PassThru -NoNewWindow
    Write-Host "Scan exit code: $($scan.ExitCode)"
    if ($TranscriptStarted) { Stop-Transcript }
    exit $scan.ExitCode
}

Write-Host "`n--- Tvsu.exe -action INSTALL ---"
$installArgs = $commonArgs + @("-action","INSTALL")
$run = Start-Process -FilePath $lsu -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
$runExit = $run.ExitCode
Write-Host "Tvsu.exe exit code: $runExit"

# Session XML is the source of truth for per-package install status.
$sessionXml = "$env:ProgramData\Lenovo\SystemUpdate\session.xml"
if (Test-Path -Path $sessionXml) {
    Write-Host "Session report: $sessionXml"
    # TODO: Parse session.xml for the Ninja custom field summary (installed / failed counts,
    # reboot-required packages, etc.) once the XML schema is confirmed on a live endpoint.
} else {
    Write-Host "Session report not found at $sessionXml"
}

if ($runExit -eq 0) {
    Write-Host "LSU run completed successfully."
} else {
    Write-Host "LSU run returned non-zero. See session.xml for per-package detail."
}

if ($TranscriptStarted) { Stop-Transcript }
exit $runExit
