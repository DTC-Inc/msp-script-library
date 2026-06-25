## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## NinjaRMM passes script preset variables as environment variables, so each parameter defaults to its $env: value.
## $Description                                          / $env:Description                                          - Ticket # or initials for audit trail
## $RMMScriptPath                                        / $env:RMMScriptPath                                        - Optional log directory base provided by the RMM
## $OrgName                                              / $env:OrgName                                              - REQUIRED. Organizational identifier used to namespace shared state under %PUBLIC% (e.g., "DTC")
## $CustomFieldGoogleChromeRemoteDesktopDetected         / $env:CustomFieldGoogleChromeRemoteDesktopDetected         - Boolean (1/0) field name (default: "googleChromeRemoteDesktopDetected")
## $CustomFieldGoogleChromeRemoteDesktopContextFoundIn   / $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn   - Text field name for context labels (default: "googleChromeRemoteDesktopContextFoundIn")
## $CustomFieldGoogleChromeRemoteDesktopFoundDetails     / $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails     - HTML field name for the formatted detail report (default: "googleChromeRemoteDesktopFoundDetails")

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-OrgName ...) or from an RMM that supplies the values as env variables.
    [string]$Description                                          = $env:Description,
    [string]$RMMScriptPath                                        = $env:RMMScriptPath,
    [string]$OrgName                                              = $env:OrgName,
    [string]$CustomFieldGoogleChromeRemoteDesktopDetected         = $env:CustomFieldGoogleChromeRemoteDesktopDetected,
    [string]$CustomFieldGoogleChromeRemoteDesktopContextFoundIn   = $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn,
    [string]$CustomFieldGoogleChromeRemoteDesktopFoundDetails     = $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails
)

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

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Name or $env:Name, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))                                        { $env:Description                                        = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath))                                      { $env:RMMScriptPath                                      = $RMMScriptPath }
if (-not [string]::IsNullOrEmpty($OrgName))                                            { $env:OrgName                                            = $OrgName }
if (-not [string]::IsNullOrEmpty($CustomFieldGoogleChromeRemoteDesktopDetected))       { $env:CustomFieldGoogleChromeRemoteDesktopDetected       = $CustomFieldGoogleChromeRemoteDesktopDetected }
if (-not [string]::IsNullOrEmpty($CustomFieldGoogleChromeRemoteDesktopContextFoundIn)) { $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn = $CustomFieldGoogleChromeRemoteDesktopContextFoundIn }
if (-not [string]::IsNullOrEmpty($CustomFieldGoogleChromeRemoteDesktopFoundDetails))   { $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails   = $CustomFieldGoogleChromeRemoteDesktopFoundDetails }

# --- Required: $env:OrgName ----------------------------------------------
# OrgName namespaces the shared state under %PUBLIC%\<OrgName>\rmm-db\.
# It must be supplied via -OrgName or the $env:OrgName RMM preset variable -- there is no prompt.

if ([string]::IsNullOrEmpty($env:OrgName)) {
    Write-Host "ERROR: \$env:OrgName is required but not set. Configure the OrgName variable in your RMM script preset."
    exit 99
}

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

# --- Computed paths ------------------------------------------------------

$UserStatePath = "$env:PUBLIC\$env:OrgName\rmm-db\google-chrome-remote-desktop-user-active.json"

# --- Description default and log path -------------------------------------

if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM."
    $env:Description = "RMM Automated Scan"
}

# Store logs under $env:RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
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
Write-Host "OrgName: $env:OrgName"
Write-Host "Detected Field: $env:CustomFieldGoogleChromeRemoteDesktopDetected"
Write-Host "Context Field: $env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn"
Write-Host "Details Field: $env:CustomFieldGoogleChromeRemoteDesktopFoundDetails"
Write-Host "User State Path: $UserStatePath"
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
$userState = Read-CRDUserState -Path $UserStatePath
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

if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
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
