## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                                  - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                                          - Ticket # or initials for audit trail
## $env:RMMScriptPath                                        - Optional log directory base provided by the RMM
## $env:CustomFieldGoogleChromeRemoteDesktopDetected         - Boolean (1/0) field name (default: "googleChromeRemoteDesktopDetected")
## $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn   - Text field name for context labels (default: "googleChromeRemoteDesktopContextFoundIn")
## $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails     - HTML field name for the formatted detail report (default: "googleChromeRemoteDesktopFoundDetails")
## $env:GoogleChromeRemoteDesktopUserStatePath               - Path to the shared user state JSON (default: "C:\Users\Public\DTC\rmm-db\google-chrome-remote-desktop-user-active.json")

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
#   5. Reads the shared JSON state file written by the user-context
#      companion script (chrome-remote-desktop-detect-user.ps1) at user
#      login. The JSON maps username -> last-detected ISO timestamp.
#
# Why two scripts: Ninja-Property-Set only works from SYSTEM context
# (it shells out to ninjarmm-cli.exe which is in a SYSTEM-only path).
# The user-context script can't call it, so it leaves a JSON entry for
# this script to read.
#
# NinjaRMM custom fields written:
#   - Detected boolean (1/0): true if EITHER system check fires OR any
#     user has an entry in the JSON
#   - Context Found In (text): "System", "User", or "User + System"
#   - Found Details (HTML): formatted report listing the system checks
#     that fired and the usernames found in user context

$ScriptLogName = "chrome-remote-desktop-detect-system.log"

# --- Default RMM environment variables if not provided -------------------

if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeRemoteDesktopDetected)) {
    $env:CustomFieldGoogleChromeRemoteDesktopDetected = "googleChromeRemoteDesktopDetected"
}
if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn)) {
    $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn = "googleChromeRemoteDesktopContextFoundIn"
}
if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeRemoteDesktopFoundDetails)) {
    $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails = "googleChromeRemoteDesktopFoundDetails"
}
if ([string]::IsNullOrEmpty($env:GoogleChromeRemoteDesktopUserStatePath)) {
    $env:GoogleChromeRemoteDesktopUserStatePath = "C:\Users\Public\DTC\rmm-db\google-chrome-remote-desktop-user-active.json"
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
Write-Host "Detected Field: $env:CustomFieldGoogleChromeRemoteDesktopDetected"
Write-Host "Context Field: $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn"
Write-Host "Details Field: $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails"
Write-Host "User State Path: $env:GoogleChromeRemoteDesktopUserStatePath"
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

# --- JSON state helper ---------------------------------------------------

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
Write-Host "Reading user state JSON..."
$userState = Read-CRDUserState -Path $env:GoogleChromeRemoteDesktopUserStatePath
$activeUsers = @($userState.Keys | Sort-Object)
if ($activeUsers.Count -gt 0) {
    foreach ($u in $activeUsers) {
        Write-Host "  [User State] $u (last seen $($userState[$u]))"
    }
} else {
    Write-Host "  [User State] No active users in JSON"
}
Write-Host ""

Write-Host "Detection summary:"
foreach ($check in $systemChecks.GetEnumerator()) {
    $marker = if ($check.Value) { "[FOUND]" } else { "[----]" }
    Write-Host "  $marker $($check.Key)"
}
$userMarker = if ($activeUsers.Count -gt 0) { "[FOUND]" } else { "[----]" }
Write-Host "  $userMarker User State JSON ($($activeUsers.Count) active)"
Write-Host ""

# --- Compute final field values ------------------------------------------

$systemActive = $systemChecks.Values -contains $true
$userActive   = $activeUsers.Count -gt 0
$anyActive    = $systemActive -or $userActive

# Field 1: Detected (boolean 1/0)
$detected = if ($anyActive) { 1 } else { 0 }

# Field 2: Context Found In (text)
if ($systemActive -and $userActive) {
    $contextFoundIn = "User + System"
} elseif ($systemActive) {
    $contextFoundIn = "System"
} elseif ($userActive) {
    $contextFoundIn = "User"
} else {
    $contextFoundIn = ""
}

# Field 3: Found Details (HTML)
$systemHits = @()
foreach ($check in $systemChecks.GetEnumerator()) {
    if ($check.Value) { $systemHits += $check.Key }
}

$htmlBuilder = [System.Text.StringBuilder]::new()
[void]$htmlBuilder.Append('<p><strong>Chrome Remote Desktop:</strong> ')
if ($anyActive) {
    [void]$htmlBuilder.Append('<span style="color:#b22222;">Detected</span></p>')
    [void]$htmlBuilder.Append('<ul>')
    if ($systemActive) {
        [void]$htmlBuilder.Append('<li><strong>System:</strong> ' + ($systemHits -join ', ') + '</li>')
    }
    if ($userActive) {
        $userListHtml = ($activeUsers | ForEach-Object { "$_ ($($userState[$_]))" }) -join ', '
        [void]$htmlBuilder.Append('<li><strong>Users:</strong> ' + $userListHtml + '</li>')
    }
    [void]$htmlBuilder.Append('</ul>')
} else {
    [void]$htmlBuilder.Append('<span style="color:#228b22;">Not Detected</span></p>')
}
$foundDetailsHtml = $htmlBuilder.ToString()

Write-Host "============================================"
Write-Host "RESULT"
Write-Host "============================================"
Write-Host "Detected: $detected"
Write-Host "Context Found In: '$contextFoundIn'"
Write-Host "Found Details HTML:"
Write-Host $foundDetailsHtml
Write-Host "============================================"
Write-Host ""

# --- Write to NinjaRMM custom fields -------------------------------------

if ($env:RMM -eq "1") {
    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeRemoteDesktopDetected -Value $detected
        Write-Host "Wrote $detected to '$env:CustomFieldGoogleChromeRemoteDesktopDetected'"
    } catch {
        Write-Host "ERROR: Failed to write '$env:CustomFieldGoogleChromeRemoteDesktopDetected' - $_"
    }
    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn -Value $contextFoundIn
        Write-Host "Wrote '$contextFoundIn' to '$env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn'"
    } catch {
        Write-Host "ERROR: Failed to write '$env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn' - $_"
    }
    try {
        Ninja-Property-Set -Name $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails -Value $foundDetailsHtml
        Write-Host "Wrote HTML details to '$env:CustomFieldGoogleChromeRemoteDesktopFoundDetails'"
    } catch {
        Write-Host "ERROR: Failed to write '$env:CustomFieldGoogleChromeRemoteDesktopFoundDetails' - $_"
    }
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set calls"
    Write-Host "Would have written:"
    Write-Host "  $env:CustomFieldGoogleChromeRemoteDesktopDetected = $detected"
    Write-Host "  $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn = '$contextFoundIn'"
    Write-Host "  $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails = (HTML, see above)"
}

Stop-Transcript
exit $detected
