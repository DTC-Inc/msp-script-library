## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                              - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                                      - Ticket # or initials for audit trail
## $env:RMMScriptPath                                    - Optional log directory base provided by the RMM
## $env:CustomFieldGoogleChromeActiveBoolean             - Name of the NinjaRMM boolean (1/0) custom field for the unified result (default: "Remote")
## $env:CustomFieldGoogleChromeContextString             - Name of the NinjaRMM text custom field for context labels (default: "RemoteContext")
## $env:GoogleChromeRemoteDesktopStateDir                - Directory shared with the user-context script for per-user state (default: "C:\ProgramData\DTC\google-chrome-remote-desktop-state")
## $env:GoogleChromeRemoteDesktopStateMaxAgeDays         - Stale state file cutoff in days (default: 90)

# Chrome Remote Desktop Detection Script (SYSTEM context)
#
# Detects Chrome Remote Desktop presence from the SYSTEM account.
# Designed for daily scheduled runs and computer-boot triggers.
# This script is the SOLE writer to the NinjaRMM custom fields.
#
# System-side checks (all SYSTEM-visible):
#   1. HKLM uninstall registry (system-wide MSI install)
#   2. Program Files install path (system-wide)
#   3. The "chromoting" Windows service (Chrome Remote Desktop Service)
#   4. The remoting_host.exe process
#
# User-side aggregation:
#   5. Reads per-user state files written by the user-context companion
#      script (chrome-remote-desktop-detect-user.ps1) at user login.
#      Each file's presence means a user has CRD installed in HKCU or
#      %LOCALAPPDATA%. File mtime is used to age out stale entries.
#
# Why two scripts: Ninja-Property-Get and Ninja-Property-Set only work
# from SYSTEM context (they shell out to ninjarmm-cli.exe in a
# SYSTEM-only path). The user-context script can't call them, so it
# leaves a state file for this script to read.
#
# "Installed" counts as "active" for the purposes of this check, per the
# requirement that any presence of Chrome Remote Desktop should flag the
# machine.
#
# Output:
#   - Writes 1 (active anywhere) or 0 (not active) to a NinjaRMM
#     boolean field (default "Remote")
#   - Writes a context string to a NinjaRMM text field (default
#     "RemoteContext"). Possible values: "", "System", "User",
#     "System, User".
#   - Writes a detailed transcript log for troubleshooting
#   - Exit code 0 = not active, 1 = active

$ScriptLogName = "chrome-remote-desktop-detect-system.log"

# --- Default RMM environment variables if not provided -------------------
# NinjaRMM passes script preset variables as environment variables, so
# every RMM-supplied input is read from $env: throughout this script.
# Defaults are set here by writing to $env: so the rest of the script
# can reference $env:VarName at every use site.

if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeActiveBoolean)) {
    $env:CustomFieldGoogleChromeActiveBoolean = "Remote"
}
if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeContextString)) {
    $env:CustomFieldGoogleChromeContextString = "RemoteContext"
}
if ([string]::IsNullOrEmpty($env:GoogleChromeRemoteDesktopStateDir)) {
    $env:GoogleChromeRemoteDesktopStateDir = "C:\ProgramData\DTC\google-chrome-remote-desktop-state"
}
if ([string]::IsNullOrEmpty($env:GoogleChromeRemoteDesktopStateMaxAgeDays)) {
    $env:GoogleChromeRemoteDesktopStateMaxAgeDays = "90"
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
Write-Host "Chrome Remote Desktop Detection (SYSTEM)"
Write-Host "============================================"
Write-Host ""
Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"
Write-Host "Boolean Custom Field: $env:CustomFieldGoogleChromeActiveBoolean"
Write-Host "Context Custom Field: $env:CustomFieldGoogleChromeContextString"
Write-Host "State Dir: $env:GoogleChromeRemoteDesktopStateDir"
Write-Host "State Max Age (days): $env:GoogleChromeRemoteDesktopStateMaxAgeDays"
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

# Read per-user state files written by the user-context script.
# Returns a list of usernames with active (non-stale) state files.
# Purges stale files (older than $env:GoogleChromeRemoteDesktopStateMaxAgeDays).
function Get-CRDActiveUsersFromState {
    $stateDir = $env:GoogleChromeRemoteDesktopStateDir
    $maxAge   = [int]$env:GoogleChromeRemoteDesktopStateMaxAgeDays

    if (-not (Test-Path $stateDir)) {
        Write-Host "  [User State] State directory does not exist: $stateDir"
        return @()
    }

    $cutoff = (Get-Date).AddDays(-$maxAge)
    $files = Get-ChildItem -Path $stateDir -File -ErrorAction SilentlyContinue
    $activeUsers = @()

    foreach ($file in $files) {
        if ($file.LastWriteTime -lt $cutoff) {
            Write-Host "  [User State] Stale ($($file.LastWriteTime.ToString('yyyy-MM-dd'))): $($file.Name) - removing"
            try {
                Remove-Item -Path $file.FullName -Force
            } catch {
                Write-Host "  [User State] Could not remove stale file: $_"
            }
        } else {
            $username = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            Write-Host "  [User State] Active ($($file.LastWriteTime.ToString('yyyy-MM-dd'))): $username"
            $activeUsers += $username
        }
    }
    return $activeUsers
}

# --- Run detection -------------------------------------------------------

Write-Host "Running system-side detection checks..."
Write-Host ""

$systemChecks = [ordered]@{
    "HKLM Uninstall Registry" = Test-CRDInstalledHKLM
    "Program Files Install"   = Test-CRDInstallPath
    "Chromoting Service"      = Test-CRDService
    "remoting_host Process"   = Test-CRDProcess
}

Write-Host ""
Write-Host "Reading per-user state files..."
Write-Host ""
$activeUsers = Get-CRDActiveUsersFromState

Write-Host ""
Write-Host "Detection summary:"
foreach ($check in $systemChecks.GetEnumerator()) {
    $marker = if ($check.Value) { "[FOUND]" } else { "[----]" }
    Write-Host "  $marker $($check.Key)"
}
$userMarker = if ($activeUsers.Count -gt 0) { "[FOUND]" } else { "[----]" }
Write-Host "  $userMarker User State Files ($($activeUsers.Count) active)"
Write-Host ""

# Compute final state
$systemActive = $systemChecks.Values -contains $true
$userActive   = $activeUsers.Count -gt 0
$anyActive    = $systemActive -or $userActive
$result       = if ($anyActive) { 1 } else { 0 }

# Build context string from the contexts that fired
$contexts = @()
if ($systemActive) { $contexts += "System" }
if ($userActive)   { $contexts += "User" }
$contextString = ($contexts | Sort-Object) -join ', '

Write-Host "============================================"
Write-Host "RESULT"
Write-Host "============================================"
Write-Host "Active: $result"
Write-Host "Context: '$contextString'"
if ($userActive) {
    Write-Host "Active users: $($activeUsers -join ', ')"
}
Write-Host "============================================"
Write-Host ""

# --- Write to NinjaRMM custom fields -------------------------------------

# Detect whether we are actually running as SYSTEM. The Ninja cmdlets
# only work from SYSTEM context, so if this script is somehow run
# interactively or scheduled in a user context, skip the writes rather
# than logging a "Failed to start ninjarmm-cli" error message into a
# custom field.
$isSystemAccount = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem

if ($env:RMM -eq "1" -and $isSystemAccount) {
    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeActiveBoolean -Value $result
        Write-Host "Wrote $result to NinjaRMM boolean field '$env:CustomFieldGoogleChromeActiveBoolean'"
    } catch {
        Write-Host "ERROR: Failed to write boolean field '$env:CustomFieldGoogleChromeActiveBoolean' - $_"
    }

    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeContextString -Value $contextString
        Write-Host "Wrote '$contextString' to NinjaRMM context field '$env:CustomFieldGoogleChromeContextString'"
    } catch {
        Write-Host "ERROR: Failed to write context field '$env:CustomFieldGoogleChromeContextString' - $_"
    }
} else {
    if (-not $isSystemAccount) {
        Write-Host "Not running as SYSTEM (account: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)) - skipping Ninja-Property-Set calls"
    } else {
        Write-Host "Interactive mode - skipping Ninja-Property-Set calls"
    }
    Write-Host "Would have written: $env:CustomFieldGoogleChromeActiveBoolean = $result"
    Write-Host "Would have written: $env:CustomFieldGoogleChromeContextString = '$contextString'"
}

Stop-Transcript
exit $result
