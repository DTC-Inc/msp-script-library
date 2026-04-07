## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                    - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                            - Ticket # or initials for audit trail
## $env:GoogleChromeRemoteDesktopStateDir      - Directory where per-user state files live (default: "C:\ProgramData\DTC\google-chrome-remote-desktop-state")

# Chrome Remote Desktop Detection Script (USER context)
#
# Detects per-user Chrome Remote Desktop installs from the running
# user's account. Designed for user-login triggers.
#
# Checks (only meaningful in user context):
#   1. HKCU uninstall registry (per-user install)
#   2. %LOCALAPPDATA%\Google\Chrome Remote Desktop for the running user
#
# This script does NOT call NinjaRMM cmdlets. The Ninja-Property-Get and
# Ninja-Property-Set cmdlets only work when scripts run from the
# NinjaRMM agent in SYSTEM context. From user context the cmdlets fall
# over with "Failed to start ninjarmm-cli".
#
# Instead, this script writes a presence-only marker file at
# $StateDir\$env:USERNAME.txt:
#   - File present = Chrome Remote Desktop is active for this user
#   - File absent  = not active
#   - File mtime   = last detection time (used by the SYSTEM-context
#                    companion script to age out stale entries)
#
# The SYSTEM-context companion (chrome-remote-desktop-detect-system.ps1)
# reads this directory, aggregates the per-user signals with its own
# system-wide checks, and is the SOLE writer to NinjaRMM custom fields.
#
# "Installed" counts as "active" for the purposes of this check, per the
# requirement that any presence of Chrome Remote Desktop should flag the
# machine.
#
# Output:
#   - Writes/removes a state file at $StateDir\$env:USERNAME.txt
#   - Writes a detailed transcript log to user-writable %LOCALAPPDATA%
#   - Exit code 0 = not active, 1 = active

$ScriptLogName = "chrome-remote-desktop-detect-user.log"

# --- Default RMM environment variables if not provided -------------------
# NinjaRMM passes script preset variables as environment variables, so
# every RMM-supplied input is read from $env: throughout this script.
# Defaults are set here by writing to $env: so the rest of the script
# can reference $env:VarName at every use site.

if ([string]::IsNullOrEmpty($env:GoogleChromeRemoteDesktopStateDir)) {
    $env:GoogleChromeRemoteDesktopStateDir = "C:\ProgramData\DTC\google-chrome-remote-desktop-state"
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
Write-Host "State Dir: $env:GoogleChromeRemoteDesktopStateDir"
Write-Host "Running As: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Username: $env:USERNAME"
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

# --- Write/remove state file ---------------------------------------------

# Ensure the shared state directory exists. C:\ProgramData allows
# authenticated users to create subdirectories with inherited
# permissions, so each user can manage their own state file in here.
if (-not (Test-Path -Path $env:GoogleChromeRemoteDesktopStateDir)) {
    try {
        New-Item -Path $env:GoogleChromeRemoteDesktopStateDir -ItemType Directory -Force | Out-Null
        Write-Host "Created state directory: $env:GoogleChromeRemoteDesktopStateDir"
    } catch {
        Write-Host "ERROR: Could not create state directory '$env:GoogleChromeRemoteDesktopStateDir' - $_"
    }
}

$stateFile = Join-Path $env:GoogleChromeRemoteDesktopStateDir "$env:USERNAME.txt"

if ($isActive) {
    try {
        # Write empty file; presence is the signal, mtime is the timestamp
        Set-Content -Path $stateFile -Value "" -Force
        Write-Host "Wrote state file: $stateFile"
    } catch {
        Write-Host "ERROR: Could not write state file '$stateFile' - $_"
    }
} else {
    if (Test-Path $stateFile) {
        try {
            Remove-Item -Path $stateFile -Force
            Write-Host "Removed state file: $stateFile (no longer active)"
        } catch {
            Write-Host "ERROR: Could not remove state file '$stateFile' - $_"
        }
    } else {
        Write-Host "No state file present (still not active)"
    }
}

Stop-Transcript
exit $result
