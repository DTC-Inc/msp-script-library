## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:RunDCUInstall             - "1" to ensure Dell Command Update is installed (default: "1")
## $env:RunDCURun                 - "1" to invoke DCU scan + applyUpdates (default: "1")
## $env:RunDellBiosConfig         - "1" to push BIOS config via cctk (default: "0")
## $env:RunDellDebloat            - "1" to remove Dell consumer software (default: "1")
## $env:CustomFieldDellStatus     - Ninja text custom field for last-run status (default: "dellBaselineStatus")
## $env:LibTag                    - jsDelivr tag to fetch leaf scripts and libs from (default: "release")

$ScriptLogName = "dell-baseline.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:RunDCUInstall))     { $env:RunDCUInstall     = "1" }
if ([string]::IsNullOrEmpty($env:RunDCURun))         { $env:RunDCURun         = "1" }
if ([string]::IsNullOrEmpty($env:RunDellBiosConfig)) { $env:RunDellBiosConfig = "0" }
if ([string]::IsNullOrEmpty($env:RunDellDebloat))    { $env:RunDellDebloat    = "1" }
if ([string]::IsNullOrEmpty($env:CustomFieldDellStatus)) { $env:CustomFieldDellStatus = "dellBaselineStatus" }
if ([string]::IsNullOrEmpty($env:LibTag))            { $env:LibTag            = "release" }

# === LIB BOOTSTRAP ===
# TODO: Replace REPLACE_WITH_REAL_HASH values once the libs land on the @release tag.
# Capture with: Get-FileHash -Algorithm SHA256 <path-to-lib>

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
        $env:Description = "Dell Baseline"
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

# Ninja Custom Fields are written via Ninja-Property-Set when the agent CLI is present.
function Set-NinjaStatus {
    param([string] $Value)
    $cli = "$env:ProgramData\NinjaRMMAgent\ninjarmm-cli.exe"
    if (Test-Path -Path $cli) {
        try {
            & $cli set $env:CustomFieldDellStatus $Value | Out-Null
        } catch {
            Write-Host "Warning: failed to set Ninja custom field '$($env:CustomFieldDellStatus)': $_"
        }
    } else {
        Write-Host "Ninja CLI not present; status would be: $Value"
    }
}

$manufacturer = Get-OEMManufacturer
Write-Host "Manufacturer: $manufacturer"

if ($manufacturer -ne "Dell") {
    Write-Host "Not a Dell endpoint. Exiting."
    Set-NinjaStatus "Skipped: not Dell"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$dellModel = Get-DellInstalledModel
Write-Host "Dell model: $dellModel"

# Fetch + invoke a leaf script from jsDelivr at the same tag the libs came from.
# TODO: Replace REPLACE_WITH_REAL_HASH per leaf once the leaves land on @release.
function Invoke-DellLeaf {
    param(
        [Parameter(Mandatory)] [string] $LeafName,
        [Parameter(Mandatory)] [string] $Sha256
    )
    $url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-dell/$LeafName"
    $local = Join-Path $env:TEMP $LeafName
    Get-VerifiedDownload -Url $url -OutFile $local -Sha256 $Sha256 | Out-Null
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $local
    return $LASTEXITCODE
}

$leafResults = @{}
$overallStatus = "OK"

if ($env:RunDCUInstall -eq "1") {
    Write-Host "`n=== dell-command-update-install ==="
    try {
        $rc = Invoke-DellLeaf -LeafName "dell-command-update-install.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["dcuInstall"] = $rc
        if ($rc -ne 0) { $overallStatus = "DCUInstallFailed" }
    } catch {
        Write-Host "dell-command-update-install threw: $_"
        $leafResults["dcuInstall"] = -1
        $overallStatus = "DCUInstallFailed"
    }
}

if ($env:RunDCURun -eq "1" -and $overallStatus -eq "OK") {
    Write-Host "`n=== dell-command-update-run ==="
    try {
        $rc = Invoke-DellLeaf -LeafName "dell-command-update-run.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["dcuRun"] = $rc
        # DCU exit code 1 = reboot required; treat as success for status reporting.
        if ($rc -notin 0, 1) { $overallStatus = "DCURunFailed" }
    } catch {
        Write-Host "dell-command-update-run threw: $_"
        $leafResults["dcuRun"] = -1
        $overallStatus = "DCURunFailed"
    }
}

if ($env:RunDellBiosConfig -eq "1") {
    Write-Host "`n=== dell-bios-config ==="
    try {
        $rc = Invoke-DellLeaf -LeafName "dell-bios-config.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["biosConfig"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    } catch {
        Write-Host "dell-bios-config threw: $_"
        $leafResults["biosConfig"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    }
}

if ($env:RunDellDebloat -eq "1") {
    Write-Host "`n=== dell-debloat ==="
    try {
        $rc = Invoke-DellLeaf -LeafName "dell-debloat.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["debloat"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    } catch {
        Write-Host "dell-debloat threw: $_"
        $leafResults["debloat"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    }
}

Write-Host "`n=== Summary ==="
foreach ($k in $leafResults.Keys) {
    Write-Host (" {0,-12} exit={1}" -f $k, $leafResults[$k])
}
Write-Host "Overall: $overallStatus"

$statusLine = "{0} | {1} | {2}" -f $overallStatus, $dellModel, (Get-Date -Format "yyyy-MM-dd HH:mm")
Set-NinjaStatus $statusLine

if ($TranscriptStarted) { Stop-Transcript }

if ($overallStatus -eq "OK") { exit 0 } else { exit 1 }
