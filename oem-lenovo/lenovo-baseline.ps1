## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:RunLSUInstall             - "1" to ensure Lenovo System Update is installed (default: "1")
## $env:RunLSURun                 - "1" to invoke LSU scan + install (default: "1")
## $env:RunLenovoBiosConfig       - "1" to push BIOS config via WMI (default: "0")
## $env:RunLenovoDebloat          - "1" to remove Lenovo consumer software (default: "1")
## $env:CustomFieldLenovoStatus   - Ninja text custom field for last-run status (default: "lenovoBaselineStatus")
## $env:LenovoVantageCommercialAvailable - "1" if DTC has Lenovo Partner Hub enrollment and prefers
##                                  Commercial Vantage over LSU. Currently a stub: the run script
##                                  logs and falls back to LSU until the Commercial Vantage path is built.

$ScriptLogName = "lenovo-baseline.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:RunLSUInstall))       { $env:RunLSUInstall       = "1" }
if ([string]::IsNullOrEmpty($env:RunLSURun))           { $env:RunLSURun           = "1" }
if ([string]::IsNullOrEmpty($env:RunLenovoBiosConfig)) { $env:RunLenovoBiosConfig = "0" }
if ([string]::IsNullOrEmpty($env:RunLenovoDebloat))    { $env:RunLenovoDebloat    = "1" }
if ([string]::IsNullOrEmpty($env:CustomFieldLenovoStatus)) { $env:CustomFieldLenovoStatus = "lenovoBaselineStatus" }

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
        $env:Description = "Lenovo Baseline"
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
            & $cli set $env:CustomFieldLenovoStatus $Value | Out-Null
        } catch {
            Write-Host "Warning: failed to set Ninja custom field '$($env:CustomFieldLenovoStatus)': $_"
        }
    } else {
        Write-Host "Ninja CLI not present; status would be: $Value"
    }
}

$manufacturer = Get-OEMManufacturer
Write-Host "Manufacturer: $manufacturer"

if ($manufacturer -ne "Lenovo") {
    Write-Host "Not a Lenovo endpoint. Exiting."
    Set-NinjaStatus "Skipped: not Lenovo"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

$lenovoModel = Get-LenovoInstalledModel
$lenovoMachineType = Get-LenovoMachineType
Write-Host "Lenovo model: $lenovoModel (machine type: $lenovoMachineType)"

# TODO: Commercial Vantage opt-in path. When $env:LenovoVantageCommercialAvailable = "1" AND
# DTC enrolls in Lenovo Partner Hub, swap the leaf invocation here to a Commercial Vantage
# install/run pipeline instead of LSU. Until then we fall back to LSU and log the intent.
if ($env:LenovoVantageCommercialAvailable -eq "1") {
    Write-Host "LenovoVantageCommercialAvailable=1: Commercial Vantage path not yet implemented; falling back to LSU"
}

# Fetch + invoke a leaf script from jsDelivr at the same commit SHA the libs came from.
function Invoke-LenovoLeaf {
    param([Parameter(Mandatory)] [string] $LeafName)
    $url = "$libBaseUrl/oem-lenovo/$LeafName"
    $local = Join-Path $env:TEMP $LeafName
    Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing -ErrorAction Stop
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $local
    return $LASTEXITCODE
}

$leafResults = @{}
$overallStatus = "OK"

if ($env:RunLSUInstall -eq "1") {
    Write-Host "`n=== lenovo-system-update-install ==="
    try {
        $rc = Invoke-LenovoLeaf -LeafName "lenovo-system-update-install.ps1"
        $leafResults["lsuInstall"] = $rc
        if ($rc -ne 0) { $overallStatus = "LSUInstallFailed" }
    } catch {
        Write-Host "lenovo-system-update-install threw: $_"
        $leafResults["lsuInstall"] = -1
        $overallStatus = "LSUInstallFailed"
    }
}

if ($env:RunLSURun -eq "1" -and $overallStatus -eq "OK") {
    Write-Host "`n=== lenovo-system-update-run ==="
    try {
        $rc = Invoke-LenovoLeaf -LeafName "lenovo-system-update-run.ps1"
        $leafResults["lsuRun"] = $rc
        # TODO: Tvsu.exe exit codes are not well documented. Once observed on real
        # endpoints, expand the success/reboot-required mapping. For now: 0 = success.
        if ($rc -ne 0) { $overallStatus = "LSURunFailed" }
    } catch {
        Write-Host "lenovo-system-update-run threw: $_"
        $leafResults["lsuRun"] = -1
        $overallStatus = "LSURunFailed"
    }
}

if ($env:RunLenovoBiosConfig -eq "1") {
    Write-Host "`n=== lenovo-bios-config ==="
    try {
        $rc = Invoke-LenovoLeaf -LeafName "lenovo-bios-config.ps1"
        $leafResults["biosConfig"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    } catch {
        Write-Host "lenovo-bios-config threw: $_"
        $leafResults["biosConfig"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "BiosConfigFailed" }
    }
}

if ($env:RunLenovoDebloat -eq "1") {
    Write-Host "`n=== lenovo-debloat ==="
    try {
        $rc = Invoke-LenovoLeaf -LeafName "lenovo-debloat.ps1"
        $leafResults["debloat"] = $rc
        if ($rc -ne 0 -and $overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    } catch {
        Write-Host "lenovo-debloat threw: $_"
        $leafResults["debloat"] = -1
        if ($overallStatus -eq "OK") { $overallStatus = "DebloatFailed" }
    }
}

Write-Host "`n=== Summary ==="
foreach ($k in $leafResults.Keys) {
    Write-Host (" {0,-12} exit={1}" -f $k, $leafResults[$k])
}
Write-Host "Overall: $overallStatus"

$statusLine = "{0} | {1} | {2}" -f $overallStatus, $lenovoModel, (Get-Date -Format "yyyy-MM-dd HH:mm")
Set-NinjaStatus $statusLine

if ($TranscriptStarted) { Stop-Transcript }

if ($overallStatus -eq "OK") { exit 0 } else { exit 1 }
