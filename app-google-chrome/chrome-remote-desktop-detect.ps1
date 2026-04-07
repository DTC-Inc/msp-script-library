## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $Description       - Ticket # or initials for audit trail
## $NinjaCustomField  - Name of the NinjaRMM custom field to write the result to (default: "Remote")

# Chrome Remote Desktop Detection Script
#
# Detects whether Chrome Remote Desktop is installed or actively running on
# the endpoint. Chrome Remote Desktop installs into multiple locations
# depending on whether it was installed system-wide or per-user via the
# Chrome browser, so this script checks all of them:
#
#   1. HKLM uninstall registry (system-wide MSI install)
#   2. HKCU uninstall registry for every loaded user hive (per-user install)
#   3. Program Files install path (system-wide)
#   4. %LOCALAPPDATA%\Google\Chrome Remote Desktop for every user profile
#   5. The "chromoting" Windows service (Chrome Remote Desktop Service)
#   6. The remoting_host.exe process
#
# "Installed" counts as "active" for the purposes of this check, per the
# requirement that any presence of Chrome Remote Desktop should flag the
# machine.
#
# Output:
#   - Writes 1 (active) or 0 (not active) to a NinjaRMM custom field
#   - Writes a detailed transcript log for troubleshooting
#   - Exit code 0 = not active, 1 = active

$ScriptLogName = "chrome-remote-desktop-detect.log"

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
if ([string]::IsNullOrEmpty($NinjaCustomField)) {
    $NinjaCustomField = "Remote"
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "============================================"
Write-Host "Chrome Remote Desktop Detection"
Write-Host "============================================"
Write-Host ""
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Ninja Custom Field: $NinjaCustomField"
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

# Check HKCU uninstall keys for every loaded user hive
# Chrome Remote Desktop is commonly installed per-user via the Chrome
# browser and lives only in HKCU, so HKLM-only checks miss it.
function Test-CRDInstalledHKCU {
    $found = $false

    # Make sure HKU is mounted (it always is, but be defensive)
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
    }

    # Iterate every loaded user hive (skip _Classes and well-known SIDs)
    $userHives = Get-ChildItem -Path "HKU:\" -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch "_Classes$" -and
        $_.PSChildName -notin @(".DEFAULT", "S-1-5-18", "S-1-5-19", "S-1-5-20")
    }

    foreach ($hive in $userHives) {
        $uninstallPaths = @(
            "HKU:\$($hive.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKU:\$($hive.PSChildName)\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($path in $uninstallPaths) {
            $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -like "*Chrome Remote Desktop*"
            }
            if ($apps) {
                foreach ($app in $apps) {
                    Write-Host "  [HKU\$($hive.PSChildName)] Found: $($app.DisplayName) ($($app.DisplayVersion))"
                }
                $found = $true
            }
        }
    }
    return $found
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

# Check %LOCALAPPDATA% for every user profile on the box
function Test-CRDUserAppData {
    $found = $false
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notin @('Public', 'Default', 'Default User', 'All Users')
    }

    foreach ($userProfile in $userProfiles) {
        $crdPath = Join-Path $userProfile.FullName "AppData\Local\Google\Chrome Remote Desktop"
        if (Test-Path $crdPath) {
            Write-Host "  [Profile] Found in $($userProfile.Name): $crdPath"
            $found = $true
        }
    }
    return $found
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
    "HKLM Uninstall Registry"   = Test-CRDInstalledHKLM
    "HKCU Uninstall Registry"   = Test-CRDInstalledHKCU
    "Program Files Install"     = Test-CRDInstallPath
    "User AppData Install"      = Test-CRDUserAppData
    "Chromoting Service"        = Test-CRDService
    "remoting_host Process"     = Test-CRDProcess
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
        Ninja-Property-Set -Name $NinjaCustomField -Value $result
        Write-Host "Wrote $result to NinjaRMM custom field '$NinjaCustomField'"
    } catch {
        Write-Host "ERROR: Failed to write to NinjaRMM custom field '$NinjaCustomField' - $_"
    }
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set call"
    Write-Host "Would have written: Ninja-Property-Set -Name '$NinjaCustomField' -Value $result"
}

Stop-Transcript
exit $result
