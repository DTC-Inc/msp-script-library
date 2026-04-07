## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                          - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                                  - Ticket # or initials for audit trail
## $env:OrgName                                      - REQUIRED. Organizational identifier used to namespace shared state under %PUBLIC% (e.g., "DTC")

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
# NinjaRMM agent in SYSTEM context.
#
# Instead, this script maintains a single shared JSON file at
# C:\Users\Public\DTC\rmm-db\google-chrome-remote-desktop-user-active.json
# that maps username -> last-detected ISO timestamp:
#
#   {
#     "WilmaGarraway": "2026-04-07T13:45:00Z",
#     "BobSmith":      "2026-04-06T09:12:00Z"
#   }
#
# When CRD is detected this script adds/updates its own entry. When
# CRD is no longer detected this script removes its own entry.
#
# The SYSTEM-context companion (chrome-remote-desktop-detect-system.ps1)
# reads this JSON, combines it with system-side detection, and writes
# the unified result to NinjaRMM custom fields.

$ScriptLogName = "chrome-remote-desktop-detect-user.log"

# --- Required: $env:OrgName ----------------------------------------------
# OrgName namespaces the shared state under %PUBLIC%\<OrgName>\rmm-db\.
# It must be set in the RMM script preset (or interactively for testing).

if ([string]::IsNullOrEmpty($env:OrgName)) {
    if ($env:RMM -eq "1") {
        Write-Host "ERROR: \$env:OrgName is required but not set. Configure the OrgName variable in your RMM script preset."
        exit 99
    } else {
        while ([string]::IsNullOrEmpty($env:OrgName)) {
            $env:OrgName = Read-Host "Please enter the OrgName (organizational identifier, e.g. 'DTC')"
        }
    }
}

# --- Computed paths ------------------------------------------------------

$UserStatePath = "$env:PUBLIC\$env:OrgName\rmm-db\google-chrome-remote-desktop-user-active.json"

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
    $LogPath = "$env:LOCALAPPDATA\$env:OrgName-logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:LOCALAPPDATA\$env:OrgName-logs\$ScriptLogName"
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
Write-Host "OrgName: $env:OrgName"
Write-Host "User State Path: $UserStatePath"
Write-Host "Running As: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Username: $env:USERNAME"
Write-Host "Scan Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# --- Detection functions -------------------------------------------------

# Check HKCU uninstall keys for the running user.
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

# Check %LOCALAPPDATA% for the running user.
function Test-CRDUserAppData {
    $crdPath = Join-Path $env:LOCALAPPDATA "Google\Chrome Remote Desktop"
    if (Test-Path $crdPath) {
        Write-Host "  [LocalAppData] Found: $crdPath"
        return $true
    }
    return $false
}

# --- JSON state helpers --------------------------------------------------

function Read-CRDUserState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{} }
    try {
        $raw = Get-Content -Raw -Path $Path -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $hash = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $hash[$prop.Name] = $prop.Value
        }
        return $hash
    } catch {
        Write-Host "  Could not read existing state file (treating as empty): $_"
        return @{}
    }
}

function Write-CRDUserState {
    param(
        [string]$Path,
        [hashtable]$State
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Host "Created state directory: $dir"
    }
    ($State | ConvertTo-Json -Depth 5) | Set-Content -Path $Path -Force
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

# --- Update shared JSON state file ---------------------------------------

$state = Read-CRDUserState -Path $UserStatePath

if ($isActive) {
    $state[$env:USERNAME] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "Adding/updating $env:USERNAME in user state file"
} else {
    if ($state.ContainsKey($env:USERNAME)) {
        $state.Remove($env:USERNAME)
        Write-Host "Removing $env:USERNAME from user state file (no longer active)"
    } else {
        Write-Host "$env:USERNAME not in user state file (still not active)"
    }
}

try {
    Write-CRDUserState -Path $UserStatePath -State $state
    Write-Host "Wrote user state file: $UserStatePath"
} catch {
    Write-Host "ERROR: Could not write user state file - $_"
}

Stop-Transcript
exit $result
