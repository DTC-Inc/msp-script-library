## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                  - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                          - Ticket # or initials for audit trail
## $env:RMMScriptPath                        - Optional log directory base provided by the RMM
## $env:CustomFieldGoogleChromeActiveBoolean - Name of the NinjaRMM boolean (1/0) custom field for THIS script's result (default: "RemoteUser")
## $env:CustomFieldGoogleChromeContextString - Name of the NinjaRMM text custom field shared with the system-context script (default: "RemoteContext")

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
#   - Writes 1 (active) or 0 (not active) to a per-script boolean field
#     (default "RemoteUser" for this script, "Remote" for the companion)
#   - Updates a SHARED text field (default "RemoteContext") that both
#     scripts contribute to. The script reads the current value, adds
#     or removes its own context label ("User"), and writes back.
#     Possible final values: "", "System", "User", "System, User".
#   - Writes a detailed transcript log for troubleshooting
#   - Exit code 0 = not active, 1 = active
#
# Field collision notes:
#   The boolean fields default to DIFFERENT names so this user-context
#   script doesn't overwrite the system result on every login. The
#   shared text field is safe because the read-merge-write logic
#   preserves the other script's contribution.

$ScriptLogName = "chrome-remote-desktop-detect-user.log"

# --- Default RMM environment variables if not provided -------------------
# NinjaRMM passes script preset variables as environment variables, so
# every RMM-supplied input is read from $env: throughout this script.
# Defaults are set here by writing to $env: so the rest of the script
# can reference $env:VarName at every use site.

if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeActiveBoolean)) {
    $env:CustomFieldGoogleChromeActiveBoolean = "RemoteUser"
}
if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeContextString)) {
    $env:CustomFieldGoogleChromeContextString = "RemoteContext"
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
    $LogPath = "$env:LOCALAPPDATA\dtc-logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:LOCALAPPDATA\dtc-logs\$ScriptLogName"
    }
    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM."
        $env:Description = "RMM Automated Scan"
    }
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
Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"
Write-Host "Boolean Custom Field: $env:CustomFieldGoogleChromeActiveBoolean"
Write-Host "Context Custom Field: $env:CustomFieldGoogleChromeContextString"
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
if ($env:RMM -eq "1") {
    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeActiveBoolean -Value $result
        Write-Host "Wrote $result to NinjaRMM boolean field '$env:CustomFieldGoogleChromeActiveBoolean'"
    } catch {
        Write-Host "ERROR: Failed to write boolean field '$env:CustomFieldGoogleChromeActiveBoolean' - $_"
    }

    Update-CRDContextField -FieldName $env:CustomFieldGoogleChromeContextString -ThisContext "User" -IsActive ([bool]$isActive)
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set calls"
    Write-Host "Would have written: $env:CustomFieldGoogleChromeActiveBoolean = $result"
    Write-Host "Would have updated context field '$env:CustomFieldGoogleChromeContextString' with label 'User' (active = $isActive)"
}

Stop-Transcript
exit $result
