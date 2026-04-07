## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $Description                          - Ticket # or initials for audit trail
## $CustomFieldGoogleChromeActiveBoolean - Name of the NinjaRMM custom field to write the result to (default: "RemoteUser")

# Chrome Remote Desktop Detection Script (USER context)
#
# Detects per-user Chrome Remote Desktop installs from the running
# user's account. Designed for user-login triggers.
#
# Checks (only meaningful in user context):
#   1. HKCU uninstall registry (per-user install)
#   2. %LOCALAPPDATA%\Google\Chrome Remote Desktop for the running user
#
# This script does NOT check HKLM, Program Files, the chromoting
# service, or the remoting_host process. Those are SYSTEM-visible and
# handled by the system-context companion script
# (chrome-remote-desktop-detect-system.ps1).
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
#   This script and the system-context companion default to DIFFERENT
#   custom field names ("RemoteUser" vs "Remote") so they don't
#   overwrite each other. OR them together in NinjaRMM dashboards or
#   conditions to get a single "CRD anywhere" signal.

$ScriptLogName = "chrome-remote-desktop-detect-user.log"

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
    $LogPath = "$ENV:LOCALAPPDATA\dtc-logs\$ScriptLogName"
} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:LOCALAPPDATA\dtc-logs\$ScriptLogName"
    }
    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM."
        $Description = "RMM Automated Scan"
    }
}

# Default custom field name if not provided by RMM
if ([string]::IsNullOrEmpty($CustomFieldGoogleChromeActiveBoolean)) {
    $CustomFieldGoogleChromeActiveBoolean = "RemoteUser"
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "============================================"
Write-Host "Chrome Remote Desktop Detection (USER)"
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

# Check HKCU uninstall keys for the running user
# Chrome Remote Desktop is commonly installed per-user via the Chrome
# browser and lives only in HKCU.
function Test-CRDInstalledHKCU {
    $registryPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $registryPaths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*Chrome Remote Desktop*"
        }
        if ($apps) {
            foreach ($app in $apps) {
                Write-Host "  [HKCU] Found: $($app.DisplayName) ($($app.DisplayVersion))"
            }
            return $true
        }
    }
    return $false
}

# Check %LOCALAPPDATA% for the running user
function Test-CRDUserAppData {
    $crdPath = Join-Path $env:LOCALAPPDATA "Google\Chrome Remote Desktop"
    if (Test-Path $crdPath) {
        Write-Host "  [LocalAppData] Found: $crdPath"
        return $true
    }
    return $false
}

# --- Run detection -------------------------------------------------------

Write-Host "Running detection checks..."
Write-Host ""

$checks = [ordered]@{
    "HKCU Uninstall Registry" = Test-CRDInstalledHKCU
    "User AppData Install"    = Test-CRDUserAppData
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
