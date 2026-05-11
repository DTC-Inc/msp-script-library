## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:HPBiosPolicyURL           - jsDelivr URL of the .repset policy file to apply
##                                  (default: dtc-baseline.repset in this repo at $LibTag)
## $env:HPBiosPolicySha256        - SHA256 of the policy file (TODO: capture and pin)
## $env:HPBiosAdminPasswordFile   - Optional path to a binary password file produced by
##                                  HPQPswd64.exe (passed to BCU via /cspwdfile)
## $env:LibTag                    - jsDelivr tag for shared libs and policy file (default: "release")

$ScriptLogName = "hp-bios-config.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:LibTag)) { $env:LibTag = "release" }
if ([string]::IsNullOrEmpty($env:HPBiosPolicyURL)) {
    $env:HPBiosPolicyURL = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-hp/policy/dtc-baseline.repset"
}
# TODO: Capture SHA256 of the .repset policy file once it lands at the URL above.
# TODO: Author oem-hp/policy/dtc-baseline.repset by running
# `BiosConfigUtility64.exe /getconfig:current.repset` on a known-good HP and editing
# the active values (*-prefixed lines) to the DTC baseline (Secure Boot enabled, WOL
# disabled, etc.). Commit at that path so the URL above resolves.
if ([string]::IsNullOrEmpty($env:HPBiosPolicySha256)) {
    $env:HPBiosPolicySha256 = "REPLACE_WITH_REAL_HASH"
}

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
        $env:Description = "HP BIOS Config"
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

$bcu = Get-HPBCUPath
if (-not $bcu) {
    Write-Host "BiosConfigUtility64.exe not found. HP BIOS Configuration Utility must be installed before this script can run."
    Write-Host "Checked: Program Files (x86)\Hewlett-Packard\BIOS Configuration Utility\, Program Files\Hewlett-Packard\BIOS Configuration Utility\, and the HP\BIOS Configuration Utility\ variants."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

Write-Host "BCU path: $bcu"

$policyPath = Join-Path $env:TEMP "dtc-hp-baseline.repset"
try {
    Get-VerifiedDownload -Url $env:HPBiosPolicyURL -OutFile $policyPath -Sha256 $env:HPBiosPolicySha256 | Out-Null
} catch {
    Write-Host "Failed to fetch BIOS policy: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

$bcuLog = Join-Path $env:TEMP "hp-bcu.log"
Write-Host "Applying policy: $policyPath"

# Reference: https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/BIOS_Configuration_Utility_User_Guide.pdf
$bcuArgs = @("/setconfig:$policyPath", "/log:$bcuLog")
if (-not [string]::IsNullOrEmpty($env:HPBiosAdminPasswordFile) -and (Test-Path -Path $env:HPBiosAdminPasswordFile)) {
    $bcuArgs += "/cspwdfile:$env:HPBiosAdminPasswordFile"
}

$proc = Start-Process -FilePath $bcu -ArgumentList $bcuArgs -Wait -PassThru -NoNewWindow
$bcuExit = $proc.ExitCode
Write-Host "BCU exit code: $bcuExit"

Remove-Item -Path $policyPath -Force -ErrorAction SilentlyContinue

if ($TranscriptStarted) { Stop-Transcript }
exit $bcuExit
