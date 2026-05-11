## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:DellBiosPolicyURL         - jsDelivr URL of the .cctk policy file to apply
##                                  (default: dtc-baseline.cctk in this repo at $LibTag)
## $env:DellBiosPolicySha256      - SHA256 of the policy file (TODO: capture and pin)
## $env:DellBiosAdminPassword     - Optional current BIOS admin password (passed to cctk via --valsetuppwd)
## $env:LibTag                    - jsDelivr tag for shared libs and policy file (default: "release")

$ScriptLogName = "dell-bios-config.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:LibTag)) { $env:LibTag = "release" }
if ([string]::IsNullOrEmpty($env:DellBiosPolicyURL)) {
    $env:DellBiosPolicyURL = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@$($env:LibTag)/oem-dell/policy/dtc-baseline.cctk"
}
# TODO: Capture SHA256 of the .cctk policy file once it lands at the URL above.
if ([string]::IsNullOrEmpty($env:DellBiosPolicySha256)) {
    $env:DellBiosPolicySha256 = "REPLACE_WITH_REAL_HASH"
}

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
        $env:Description = "Dell BIOS Config"
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

# cctk.exe is installed by Dell Command Configure. Dell ships both 32-bit and 64-bit binaries.
$cctkCandidates = @(
    "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe",
    "${env:ProgramFiles(x86)}\Dell\Command Configure\X86\cctk.exe"
)
$cctk = $null
foreach ($candidate in $cctkCandidates) {
    if (Test-Path -Path $candidate) {
        $cctk = $candidate
        break
    }
}

if (-not $cctk) {
    Write-Host "cctk.exe not found. Dell Command Configure must be installed before this script can run."
    Write-Host "Checked: $($cctkCandidates -join '; ')"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 2
}

Write-Host "cctk path: $cctk"

$policyPath = Join-Path $env:TEMP "dtc-dell-baseline.cctk"
try {
    Get-VerifiedDownload -Url $env:DellBiosPolicyURL -OutFile $policyPath -Sha256 $env:DellBiosPolicySha256 | Out-Null
} catch {
    Write-Host "Failed to fetch BIOS policy: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

Write-Host "Applying policy: $policyPath"

# Reference: https://www.dell.com/support/manuals/en-us/command-configure-v4.1/dcc_ug_4.1.0/applying-ini-or-cctk-file
$cctkArgs = @("--infile=$policyPath")
if (-not [string]::IsNullOrEmpty($env:DellBiosAdminPassword)) {
    $cctkArgs += "--valsetuppwd=$env:DellBiosAdminPassword"
}

$proc = Start-Process -FilePath $cctk -ArgumentList $cctkArgs -Wait -PassThru -NoNewWindow
$cctkExit = $proc.ExitCode
Write-Host "cctk exit code: $cctkExit"

Remove-Item -Path $policyPath -Force -ErrorAction SilentlyContinue

if ($TranscriptStarted) { Stop-Transcript }
exit $cctkExit
