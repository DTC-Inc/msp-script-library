## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:HPIAScanOnly              - "1" to analyze without applying updates (default: "0")
## $env:HPIACategory              - HPIA /Category value (default: "Drivers,Software,Firmware,BIOS")
## $env:HPIAReportFolder          - HPIA /ReportFolder path (default: "C:\ProgramData\DTC\HPIA\Report")
## $env:HPIASoftpaqFolder         - HPIA /SoftpaqDownloadFolder path (default: "C:\ProgramData\DTC\HPIA\Softpaqs")
## $env:LibTag                    - jsDelivr tag for shared libs (default: "release")

$ScriptLogName = "hp-image-assistant-run.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:HPIAScanOnly))      { $env:HPIAScanOnly      = "0" }
if ([string]::IsNullOrEmpty($env:HPIACategory))      { $env:HPIACategory      = "Drivers,Software,Firmware,BIOS" }
if ([string]::IsNullOrEmpty($env:HPIAReportFolder))  { $env:HPIAReportFolder  = "C:\ProgramData\DTC\HPIA\Report" }
if ([string]::IsNullOrEmpty($env:HPIASoftpaqFolder)) { $env:HPIASoftpaqFolder = "C:\ProgramData\DTC\HPIA\Softpaqs" }
if ([string]::IsNullOrEmpty($env:LibTag))            { $env:LibTag            = "release" }

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
        $env:Description = "HP Image Assistant Run"
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

if (-not (Test-HPIAInstalled)) {
    Write-Host "HP Image Assistant is not installed. Run hp-image-assistant-install.ps1 first."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

$hpia = Get-HPIAPath
Write-Host "HPIA: $hpia (version $(Get-HPIAVersion))"

# Ensure report + softpaq folders exist so HPIA can write into them.
foreach ($folder in @($env:HPIAReportFolder, $env:HPIASoftpaqFolder)) {
    if (-not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
}

# Reference: https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf
# Exit codes for /Operation:Analyze /Action:Install (16-bit packed):
#   0    = success, completed (or nothing to do)
#   256  = analyze returned no recommendations; treat as success
#   257  = success, reboot required
#   3010 = SoftPaqs installed, one or more require reboot
#   4096 / 4097 / 8194 / 8199 = failure paths (log + non-zero exit)

if ($env:HPIAScanOnly -eq "1") {
    Write-Host "`n--- HPIA /Operation:Analyze /Action:List (scan only) ---"
    $hpiaArgs = @(
        "/Operation:Analyze",
        "/Action:List",
        "/Category:$env:HPIACategory",
        "/Silent",
        "/ReportFolder:$env:HPIAReportFolder"
    )
    $scan = Start-Process -FilePath $hpia -ArgumentList $hpiaArgs -Wait -PassThru -NoNewWindow
    Write-Host "Scan exit code: $($scan.ExitCode)"
    if ($TranscriptStarted) { Stop-Transcript }
    exit $scan.ExitCode
}

Write-Host "`n--- HPIA /Operation:Analyze /Action:Install ---"
$hpiaArgs = @(
    "/Operation:Analyze",
    "/Action:Install",
    "/Category:$env:HPIACategory",
    "/Selection:All",
    "/Silent",
    "/ReportFolder:$env:HPIAReportFolder",
    "/SoftpaqDownloadFolder:$env:HPIASoftpaqFolder",
    "/AutoCleanup:Enable"
)
$apply = Start-Process -FilePath $hpia -ArgumentList $hpiaArgs -Wait -PassThru -NoNewWindow
$applyExit = $apply.ExitCode
Write-Host "Apply exit code: $applyExit"

switch ($applyExit) {
    0    { Write-Host "HPIA completed successfully." }
    256  { Write-Host "HPIA analyzed and returned no recommendations." }
    257  { Write-Host "Updates applied; reboot required to complete." }
    3010 { Write-Host "SoftPaqs installed; one or more require reboot." }
    4096 { Write-Host "HPIA failure: general error." }
    4097 { Write-Host "HPIA failure: invalid parameters." }
    8194 { Write-Host "HPIA failure: download error." }
    8199 { Write-Host "HPIA failure: install error." }
    default { Write-Host "Unrecognized HPIA exit code: $applyExit" }
}

if ($TranscriptStarted) { Stop-Transcript }
exit $applyExit
