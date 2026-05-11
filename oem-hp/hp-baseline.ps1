## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:RunHPIAInstall            - "1" to ensure HP Image Assistant is installed (default: "1")
## $env:RunHPIARun                - "1" to invoke HPIA analyze + install (default: "1")
## $env:RunHPBiosConfig           - "1" to push BIOS config via BCU (default: "0")
## $env:RunHPDebloat              - "1" to remove HP consumer software (default: "1")
## $env:CustomFieldHPStatus       - Ninja text custom field for last-run status (default: "hpBaselineStatus")
## $env:LibTag                    - jsDelivr tag to fetch leaf scripts and libs from (default: "release")

$ScriptLogName = "hp-baseline.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:RunHPIAInstall))    { $env:RunHPIAInstall    = "1" }
if ([string]::IsNullOrEmpty($env:RunHPIARun))        { $env:RunHPIARun        = "1" }
if ([string]::IsNullOrEmpty($env:RunHPBiosConfig))   { $env:RunHPBiosConfig   = "0" }
if ([string]::IsNullOrEmpty($env:RunHPDebloat))      { $env:RunHPDebloat      = "1" }
if ([string]::IsNullOrEmpty($env:CustomFieldHPStatus)) { $env:CustomFieldHPStatus = "hpBaselineStatus" }
if ([string]::IsNullOrEmpty($env:LibTag))            { $env:LibTag            = "release" }

# === LIB BOOTSTRAP ===
# TODO: Replace REPLACE_WITH_REAL_HASH values once the libs land on the @release tag.
# Capture with: Get-FileHash -Algorithm SHA256 <path-to-lib>

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
        $env:Description = "HP Baseline"
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
            & $cli set $env:CustomFieldHPStatus $Value | Out-Null
        } catch {
            Write-Host "Warning: failed to set Ninja custom field '$($env:CustomFieldHPStatus)': $_"
        }
    } else {
        Write-Host "Ninja CLI not present; status would be: $Value"
    }
}

$manufacturer = Get-OEMManufacturer
Write-Host "Manufacturer: $manufacturer"

if ($manufacturer -ne "HP") {
    Write-Host "Not an HP endpoint. Exiting."
    Set-NinjaStatus "Skipped: not HP"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$hpModel = Get-HPInstalledModel
Write-Host "HP model: $hpModel"

# Fetch + invoke a leaf script from jsDelivr at the same tag the libs came from.
# TODO: Replace REPLACE_WITH_REAL_HASH per leaf once the leaves land on @release.
function Invoke-HPLeaf {
    param(
        [Parameter(Mandatory)] [string] $LeafName,
        [Parameter(Mandatory)] [string] $Sha256
    )
    $url = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-hp/$LeafName"
    $local = Join-Path $env:TEMP $LeafName
    Get-VerifiedDownload -Url $url -OutFile $local -Sha256 $Sha256 | Out-Null
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $local
    return $LASTEXITCODE
}

$leafResults = @{}
$overallStatus = "OK"

if ($env:RunHPIAInstall -eq "1") {
    Write-Host "`n=== hp-image-assistant-install ==="
    try {
        $rc = Invoke-HPLeaf -LeafName "hp-image-assistant-install.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["hpiaInstall"] = $rc
        if ($rc -ne 0) { $overallStatus = "HPIAInstallFailed" }
    } catch {
        Write-Host "hp-image-assistant-install threw: $_"
        $leafResults["hpiaInstall"] = -1
        $overallStatus = "HPIAInstallFailed"
    }
}

if ($env:RunHPIARun -eq "1" -and $overallStatus -eq "OK") {
    Write-Host "`n=== hp-image-assistant-run ==="
    try {
        $rc = Invoke-HPLeaf -LeafName "hp-image-assistant-run.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["hpiaRun"] = $rc
        # HPIA exit codes 0 / 256 = OK; 257 / 3010 = reboot required (treat as success).
        if ($rc -notin 0, 256, 257, 3010) { $overallStatus = "HPIARunFailed" }
    } catch {
        Write-Host "hp-image-assistant-run threw: $_"
        $leafResults["hpiaRun"] = -1
        $overallStatus = "HPIARunFailed"
    }
}

if ($env:RunHPBiosConfig -eq "1") {
    Write-Host "`n=== hp-bios-config ==="
    try {
        $rc = Invoke-HPLeaf -LeafName "hp-bios-config.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["biosConfig"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    } catch {
        Write-Host "hp-bios-config threw: $_"
        $leafResults["biosConfig"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    }
}

if ($env:RunHPDebloat -eq "1") {
    Write-Host "`n=== hp-debloat ==="
    try {
        $rc = Invoke-HPLeaf -LeafName "hp-debloat.ps1" -Sha256 "REPLACE_WITH_REAL_HASH"
        $leafResults["debloat"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    } catch {
        Write-Host "hp-debloat threw: $_"
        $leafResults["debloat"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    }
}

Write-Host "`n=== Summary ==="
foreach ($k in $leafResults.Keys) {
    Write-Host (" {0,-12} exit={1}" -f $k, $leafResults[$k])
}
Write-Host "Overall: $overallStatus"

$statusLine = "{0} | {1} | {2}" -f $overallStatus, $hpModel, (Get-Date -Format "yyyy-MM-dd HH:mm")
Set-NinjaStatus $statusLine

if ($TranscriptStarted) { Stop-Transcript }

if ($overallStatus -eq "OK") { exit 0 } else { exit 1 }
