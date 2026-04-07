## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $Description                          - Ticket # or initials for audit trail
## $CustomFieldGoogleChromeActiveBoolean - Name of the NinjaRMM boolean (1/0) custom field for THIS script's result (default: "Remote")
## $CustomFieldGoogleChromeContextString - Name of the NinjaRMM text custom field shared with the user-context script (default: "RemoteContext")

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
#   - Writes 1 (active) or 0 (not active) to a per-script boolean field
#     (default "Remote" for this script, "RemoteUser" for the companion)
#   - Updates a SHARED text field (default "RemoteContext") that both
#     scripts contribute to. The script reads the current value, adds
#     or removes its own context label ("System"), and writes back.
#     Possible final values: "", "System", "User", "System, User".
#   - Writes a detailed transcript log for troubleshooting
#   - Exit code 0 = not active, 1 = active
#
# Field collision notes:
#   The boolean fields default to DIFFERENT names so the user-context
#   script doesn't overwrite the system result on every login. The
#   shared text field is safe because the read-merge-write logic
#   preserves the other script's contribution.

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

# Default custom field names if not provided by RMM
if ([string]::IsNullOrEmpty($CustomFieldGoogleChromeActiveBoolean)) {
    $CustomFieldGoogleChromeActiveBoolean = "Remote"
}
if ([string]::IsNullOrEmpty($CustomFieldGoogleChromeContextString)) {
    $CustomFieldGoogleChromeContextString = "RemoteContext"
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
Write-Host "Boolean Custom Field: $CustomFieldGoogleChromeActiveBoolean"
Write-Host "Context Custom Field: $CustomFieldGoogleChromeContextString"
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

# --- Write to NinjaRMM custom fields -------------------------------------

# Read-merge-write helper for the shared context field. Reads the
# current value, adds or removes this script's context label, and
# writes the merged result back. Preserves the other context script's
# contribution.
function Update-CRDContextField {
    param(
        [string]$FieldName,
        [string]$ThisContext,  # "System" or "User"
        [bool]$IsActive
    )

    $current = ""
    try {
        $current = Ninja-Property-Get -Name $FieldName
        if ($null -eq $current) { $current = "" }
    } catch {
        Write-Host "  Could not read existing context field (treating as empty): $_"
        $current = ""
    }

    # Parse current value into a set, drop our own label so we can re-add it
    $contexts = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $contexts = $current -split ',\s*' | Where-Object { $_ -and $_ -ne $ThisContext }
    }
    if ($IsActive) {
        $contexts += $ThisContext
    }

    # Sort alphabetically for deterministic output
    $newValue = ($contexts | Sort-Object -Unique) -join ', '

    try {
        Ninja-Property-Set -Name $FieldName -Value $newValue
        Write-Host "Updated NinjaRMM context field '$FieldName': '$current' -> '$newValue'"
    } catch {
        Write-Host "ERROR: Failed to write context field '$FieldName' - $_"
    }
}

# Only attempt the Ninja-Property-Set calls when running from the RMM,
# since the cmdlets only exist inside the NinjaRMM agent context.
if ($RMM -eq 1) {
    try {
        Ninja-Property-Set -Name $CustomFieldGoogleChromeActiveBoolean -Value $result
        Write-Host "Wrote $result to NinjaRMM boolean field '$CustomFieldGoogleChromeActiveBoolean'"
    } catch {
        Write-Host "ERROR: Failed to write boolean field '$CustomFieldGoogleChromeActiveBoolean' - $_"
    }

    Update-CRDContextField -FieldName $CustomFieldGoogleChromeContextString -ThisContext "System" -IsActive ([bool]$isActive)
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set calls"
    Write-Host "Would have written: $CustomFieldGoogleChromeActiveBoolean = $result"
    Write-Host "Would have updated context field '$CustomFieldGoogleChromeContextString' with label 'System' (active = $isActive)"
}

Stop-Transcript
exit $result
