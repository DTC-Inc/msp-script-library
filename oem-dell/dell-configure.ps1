## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM
##
## BIOS settings (operator sets the ones they want to apply, leaves others blank):
## $env:BIOS_AdminPassword        - Current BIOS admin password. Required to apply settings on most platforms. Empty = none set.
## $env:BIOS_AdminPasswordNew     - New BIOS admin password to set. Empty = don't change.
## $env:BIOS_TPMEnabled           - "Enabled" / "Disabled"
## $env:BIOS_TPMActivation        - "Activated" / "Deactivated"
## $env:BIOS_SecureBoot           - "Enabled" / "Disabled"
## $env:BIOS_VirtualizationCPU    - "Enabled" / "Disabled"
## $env:BIOS_VirtualizationIOMMU  - "Enabled" / "Disabled"
## $env:BIOS_WakeOnLAN            - "Enabled" / "Disabled" / "LANOnly" / "LANWLAN"
## $env:BIOS_BootMode             - "UEFI" / "Legacy"

$ScriptLogName = "dell-configure.log"

# --- Inlined helpers -----------------------------------------------------
# This script is self-contained. The helpers below are duplicated across
# Dell leaf scripts intentionally. See CLAUDE.md "OEM Vendor Scripts" for
# the trade-off rationale.

function Test-DellHardware {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    return ($manufacturer -like "Dell*")
}

function Get-DellInstalledModel {
    return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
}

# Dell BIOS settings translation table. Maps canonical $env:BIOS_* names to
# Dell Command Configure (cctk.exe) argument syntax.
#
# Descriptor shape:
#   @{
#       Native = '<cctk subcommand or option name>'
#       Values = @{ <CanonicalValue> = '<cctk value>' ; ... }
#       Form   = 'KeyValue' | 'Subcommand'
#   }
#
# Form='KeyValue'   emits  --<Native>=<value>             (e.g. --tpm=on)
# Form='Subcommand' emits  <Native> --<Param>=<value>     (e.g. bootorder --activebootlist=uefi)
#
# Settings Dell does not support (or that we have not validated) are absent.
# Unknown canonical names are logged and skipped so forward-looking vars
# don't break the run.
$dellBiosSettingsMap = @{
    BIOS_TPMEnabled = @{
        Native = 'tpm'
        Values = @{ Enabled = 'on'; Disabled = 'off' }
        Form   = 'KeyValue'
    }
    BIOS_TPMActivation = @{
        Native = 'tpmactivation'
        Values = @{ Activated = 'activate'; Deactivated = 'deactivate' }
        Form   = 'KeyValue'
    }
    BIOS_SecureBoot = @{
        Native = 'secureboot'
        Values = @{ Enabled = 'enabled'; Disabled = 'disabled' }
        Form   = 'KeyValue'
    }
    BIOS_VirtualizationCPU = @{
        Native = 'virtualization'
        Values = @{ Enabled = 'enable'; Disabled = 'disable' }
        Form   = 'KeyValue'
    }
    BIOS_VirtualizationIOMMU = @{
        Native = 'vtfordirectio'
        Values = @{ Enabled = 'enable'; Disabled = 'disable' }
        Form   = 'KeyValue'
    }
    BIOS_WakeOnLAN = @{
        Native = 'wakeonlan'
        Values = @{
            Enabled  = 'lan'
            Disabled = 'disable'
            LANOnly  = 'lan'
            LANWLAN  = 'lanwlan'
        }
        Form = 'KeyValue'
    }
    BIOS_BootMode = @{
        Native = 'bootorder'
        Values = @{ UEFI = 'uefi'; Legacy = 'legacy' }
        Form   = 'Subcommand'
        Param  = 'activebootlist'
    }
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
        $env:Description = "Dell Configure"
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
    Write-Host "Not a Dell endpoint. Skipping."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

Write-Host "Dell model: $(Get-DellInstalledModel)"

# cctk.exe is installed by Dell Command Configure. Dell ships both 64-bit and 32-bit binaries.
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

# Build per-setting cctk invocations from $env:BIOS_* vars via the translation map.
# Each setting is applied as its own cctk call so one bad value doesn't fail the
# rest. Password flags are appended to every call when present.

$passwordArgs = @()
if (-not [string]::IsNullOrEmpty($env:BIOS_AdminPassword)) {
    $passwordArgs += "--valsetuppwd=$env:BIOS_AdminPassword"
}

$applied = 0
$skipped = 0
$failed  = 0

foreach ($canonical in @(
    'BIOS_TPMEnabled',
    'BIOS_TPMActivation',
    'BIOS_SecureBoot',
    'BIOS_VirtualizationCPU',
    'BIOS_VirtualizationIOMMU',
    'BIOS_WakeOnLAN',
    'BIOS_BootMode'
)) {
    $value = (Get-Item -Path "Env:$canonical" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrEmpty($value)) { continue }

    if (-not $dellBiosSettingsMap.ContainsKey($canonical)) {
        Write-Host "  $canonical=$value ... no Dell translation for this setting; skipping."
        $skipped++
        continue
    }
    $desc = $dellBiosSettingsMap[$canonical]

    if (-not $desc.Values.ContainsKey($value)) {
        Write-Host "  $canonical=$value ... value not supported by Dell (allowed: $($desc.Values.Keys -join ', ')); skipping."
        $skipped++
        continue
    }

    $native = $desc.Native
    $nativeVal = $desc.Values[$value]

    switch ($desc.Form) {
        'KeyValue' {
            $cctkArgs = @("--$native=$nativeVal") + $passwordArgs
        }
        'Subcommand' {
            $cctkArgs = @($native, "--$($desc.Param)=$nativeVal") + $passwordArgs
        }
        default {
            Write-Host "  $canonical ... unknown form '$($desc.Form)' in translation map; skipping."
            $skipped++
            continue
        }
    }

    Write-Host "  $canonical=$value -> cctk $($cctkArgs -join ' ')"
    try {
        $proc = Start-Process -FilePath $cctk -ArgumentList $cctkArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            $applied++
        } else {
            # TODO: Capture cctk exit codes observed during real-endpoint testing
            # so we can map them to friendlier messages (e.g. 113 = password required).
            Write-Host "    cctk exit code: $($proc.ExitCode)"
            $failed++
        }
    } catch {
        Write-Host "    cctk invocation threw: $_"
        $failed++
    }
}

# Apply admin password change last so subsequent runs use the new password.
if (-not [string]::IsNullOrEmpty($env:BIOS_AdminPasswordNew)) {
    Write-Host "  Setting new BIOS admin password ..."
    $pwdArgs = @("--setuppwd=$env:BIOS_AdminPasswordNew") + $passwordArgs
    try {
        $proc = Start-Process -FilePath $cctk -ArgumentList $pwdArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host "    Admin password updated."
            $applied++
        } else {
            Write-Host "    cctk setuppwd exit code: $($proc.ExitCode)"
            $failed++
        }
    } catch {
        Write-Host "    cctk setuppwd threw: $_"
        $failed++
    }
}

Write-Host "`nSummary: applied=$applied skipped=$skipped failed=$failed"

if ($TranscriptStarted) { Stop-Transcript }

if ($failed -gt 0) { exit 1 } else { exit 0 }
