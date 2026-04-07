## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $Description                          - Ticket # or initials for audit trail
## $CustomFieldGoogleChromeActiveBoolean - Name of the NinjaRMM custom field to write the result to (default: "Remote")

# Chrome Remote Desktop Detection Script (SYSTEM context)
#
# Detects Chrome Remote Desktop presence from the SYSTEM account.
# Designed for daily scheduled runs and computer-boot triggers.
#
# Checks (all SYSTEM-visible):
#   1. HKLM uninstall registry (system-wide MSI install)
#   2. Program Files install path (system-wide)
#   3. The "chromoting" Windows service (Chrome Remote Desktop Service)
#   4. The remoting_host.exe process
#
# This script does NOT check HKCU or %LOCALAPPDATA% because in SYSTEM
# context those resolve to SYSTEM's profile, which never has CRD. The
# user-context companion script (chrome-remote-desktop-detect-user.ps1)
# handles per-user installs at login.
#
# "Installed" counts as "active" for the purposes of this check, per the
# requirement that any presence of Chrome Remote Desktop should flag the
# machine.
#
# Output:
#   - Writes 1 (active) or 0 (not active) to a NinjaRMM custom field
#   - Writes a detailed transcript log for troubleshooting
#   - Exit code 0 = not active, 1 = active
#
# Field collision warning:
#   This script and the user-context companion default to DIFFERENT
#   custom field names ("Remote" vs "RemoteUser") so they don't
#   overwrite each other. OR them together in NinjaRMM dashboards or
#   conditions to get a single "CRD anywhere" signal.

$ScriptLogName = "chrome-remote-desktop-detect-system.log"

# --- Input handling: RMM vs interactive ----------------------------------

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }
    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM."
        $Description = "RMM Automated Scan"
    }
}

# Default custom field name if not provided by RMM
if ([string]::IsNullOrEmpty($CustomFieldGoogleChromeActiveBoolean)) {
    $CustomFieldGoogleChromeActiveBoolean = "Remote"
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "============================================"
Write-Host "Chrome Remote Desktop Detection (SYSTEM)"
Write-Host "============================================"
Write-Host ""
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Custom Field: $CustomFieldGoogleChromeActiveBoolean"
Write-Host "Running As: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Scan Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# --- Detection functions -------------------------------------------------

# Check HKLM uninstall keys (system-wide installs)
function Test-CRDInstalledHKLM {
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $registryPaths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*Chrome Remote Desktop*"
        }
        if ($apps) {
            foreach ($app in $apps) {
                Write-Host "  [HKLM] Found: $($app.DisplayName) ($($app.DisplayVersion))"
            }
            return $true
        }
    }
    return $false
}

# Check the system-wide install path under Program Files
function Test-CRDInstallPath {
    $installPaths = @(
        "${env:ProgramFiles}\Google\Chrome Remote Desktop",
        "${env:ProgramFiles(x86)}\Google\Chrome Remote Desktop"
    )
    foreach ($path in $installPaths) {
        if (Test-Path $path) {
            Write-Host "  [Path] Found install directory: $path"
            return $true
        }
    }
    return $false
}

# Check the chromoting Windows service
function Test-CRDService {
    $service = Get-Service -Name "chromoting" -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "  [Service] chromoting service present (Status: $($service.Status), StartType: $($service.StartType))"
        return $true
    }
    return $false
}

# Check the remoting_host process
function Test-CRDProcess {
    $process = Get-Process -Name "remoting_host" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Host "  [Process] remoting_host.exe is running (PID: $($process.Id -join ', '))"
        return $true
    }
    return $false
}

# --- Run detection -------------------------------------------------------

Write-Host "Running detection checks..."
Write-Host ""

$checks = [ordered]@{
    "HKLM Uninstall Registry" = Test-CRDInstalledHKLM
    "Program Files Install"   = Test-CRDInstallPath
    "Chromoting Service"      = Test-CRDService
    "remoting_host Process"   = Test-CRDProcess
}

Write-Host ""
Write-Host "Detection summary:"
foreach ($check in $checks.GetEnumerator()) {
    $marker = if ($check.Value) { "[FOUND]" } else { "[----]" }
    Write-Host "  $marker $($check.Key)"
}
Write-Host ""

# Active if any check returned true
$isActive = $checks.Values -contains $true
$result = if ($isActive) { 1 } else { 0 }

Write-Host "============================================"
Write-Host "RESULT: Chrome Remote Desktop Active = $result"
Write-Host "============================================"
Write-Host ""

# --- Write to NinjaRMM custom field --------------------------------------

# Only attempt the Ninja-Property-Set call when running from the RMM, since
# the cmdlet only exists inside the NinjaRMM agent context.
if ($RMM -eq 1) {
    try {
        Ninja-Property-Set -Name $CustomFieldGoogleChromeActiveBoolean -Value $result
        Write-Host "Wrote $result to NinjaRMM custom field '$CustomFieldGoogleChromeActiveBoolean'"
    } catch {
        Write-Host "ERROR: Failed to write to NinjaRMM custom field '$CustomFieldGoogleChromeActiveBoolean' - $_"
    }
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set call"
    Write-Host "Would have written: Ninja-Property-Set -Name '$CustomFieldGoogleChromeActiveBoolean' -Value $result"
}

Stop-Transcript
exit $result
