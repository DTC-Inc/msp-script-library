## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:LenovoBiosPolicyURL       - jsDelivr URL of the policy file to apply
##                                  (default: dtc-baseline.lenovobios in this repo at pinned SHA)
## $env:LenovoBiosPolicySha256    - SHA256 of the policy file (TODO: capture and pin)
## $env:LenovoBiosSupervisorPassword - Optional current BIOS supervisor password.
##                                  Appended as ",<pwd>,ascii,us" to the SetBiosSetting / SaveBiosSettings
##                                  tuple when set. Required on machines with a supervisor password.

$ScriptLogName = "lenovo-bios-config.log"

# --- Default optional RMM environment variables --------------------------

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

if ([string]::IsNullOrEmpty($env:LenovoBiosPolicyURL)) {
    $env:LenovoBiosPolicyURL = "$libBaseUrl/oem-lenovo/policy/dtc-baseline.lenovobios"
}
# TODO: Capture SHA256 of dtc-baseline.lenovobios once the policy file is authored and
# committed at the URL above. The policy file is NOT included in this PR.
if ([string]::IsNullOrEmpty($env:LenovoBiosPolicySha256)) {
    $env:LenovoBiosPolicySha256 = "REPLACE_WITH_REAL_HASH"
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
        $env:Description = "Lenovo BIOS Config"
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

# Lenovo has no cctk-equivalent CLI. BIOS settings are applied via the
# root\wmi Lenovo_SetBiosSetting / Lenovo_SaveBiosSettings classes.
# Reference: https://docs.lenovocdrt.com/ref/bios/wmi/wmi_guide/
$setBiosClass = Get-WmiObject -Class Lenovo_SetBiosSetting -Namespace root\wmi -ErrorAction SilentlyContinue
$saveBiosClass = Get-WmiObject -Class Lenovo_SaveBiosSettings -Namespace root\wmi -ErrorAction SilentlyContinue

if (-not $setBiosClass -or -not $saveBiosClass) {
    Write-Host "Lenovo BIOS WMI classes not available (root\wmi Lenovo_SetBiosSetting / Lenovo_SaveBiosSettings)."
    Write-Host "This endpoint may not support WMI BIOS configuration."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

$policyPath = Join-Path $env:TEMP "dtc-lenovo-baseline.lenovobios"
try {
    Get-VerifiedDownload -Url $env:LenovoBiosPolicyURL -OutFile $policyPath -Sha256 $env:LenovoBiosPolicySha256 | Out-Null
} catch {
    Write-Host "Failed to fetch BIOS policy: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

# Policy file format: one "name,value" tuple per line. Comments start with '#'.
# Example tuples (TODO: authoritative list lives in dtc-baseline.lenovobios):
#   WakeOnLAN,Disable
#   SecureBoot,Enable
#   SecureRollBackPrevention,Enable
#   BootMode,UEFI
# Settings and values are case-sensitive. Reboot required for changes to take effect.

$pwd = $env:LenovoBiosSupervisorPassword
$pwdSuffix = if ([string]::IsNullOrEmpty($pwd)) { "" } else { ",$pwd,ascii,us" }

$applied = 0
$failed = 0
$lines = Get-Content -Path $policyPath -ErrorAction Stop
foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) { continue }

    # Tuple: "Name,Value" optionally followed by ",password,ascii,us" (built from $pwdSuffix).
    $tuple = "$trimmed$pwdSuffix"
    Write-Host "SetBiosSetting: $trimmed"
    try {
        $result = $setBiosClass.SetBiosSetting($tuple)
        if ($result.return -eq "Success") {
            $applied++
        } else {
            Write-Host "  return=$($result.return)"
            $failed++
        }
    } catch {
        Write-Host "  threw: $_"
        $failed++
    }
}

Remove-Item -Path $policyPath -Force -ErrorAction SilentlyContinue

if ($applied -gt 0) {
    Write-Host "`nCommitting changes via Lenovo_SaveBiosSettings"
    $saveTuple = if ([string]::IsNullOrEmpty($pwd)) { "" } else { "$pwd,ascii,us" }
    try {
        if ([string]::IsNullOrEmpty($saveTuple)) {
            # TODO: Confirm Lenovo_SaveBiosSettings accepts no-arg call on test endpoint.
            # Older models require a tuple arg even with empty password; newer models tolerate empty call.
            $save = $saveBiosClass.SaveBiosSettings("")
        } else {
            $save = $saveBiosClass.SaveBiosSettings($saveTuple)
        }
        Write-Host "SaveBiosSettings return: $($save.return)"
        if ($save.return -ne "Success") { $failed++ }
    } catch {
        Write-Host "SaveBiosSettings threw: $_"
        $failed++
    }
}

Write-Host "`nSummary: applied=$applied failed=$failed"

if ($TranscriptStarted) { Stop-Transcript }

if ($failed -gt 0) { exit 1 } else { exit 0 }
