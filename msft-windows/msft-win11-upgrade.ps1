## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail (default: "No Description")
## $isoUrl        / $env:isoUrl        - REQUIRED. URL of the Windows 11 ISO to download
## $forceUpgrade  / $env:forceUpgrade  - Set to 1 to add the /product server flag, 0 to skip (default: 0)
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-isoUrl ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$isoUrl        = $env:isoUrl,
    [string]$forceUpgrade  = $env:forceUpgrade,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "msft-win11-upgrade.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Name or $env:Name, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($isoUrl))        { $env:isoUrl        = $isoUrl }
if (-not [string]::IsNullOrEmpty($forceUpgrade))  { $env:forceUpgrade  = $forceUpgrade }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

<#
.SYNOPSIS
    Fully automated in-place upgrade Win10 → Win11 with pre-flight checks and enhanced setup flags.

.DESCRIPTION
    Optimized for RMM execution under SYSTEM with minimal user interaction.

    Reports progress at 0 %, 25 %, 50 %, 75 %:
      0 % – script start
      25 % – download beginning
      50 % – download finished & ISO mounted
      75 % – setup.exe launched

    Pre-flight checks:
    - Validates 20GB minimum free disk space
    - Checks for pending reboots
    - Cleans temporary files

    Enhanced setup.exe arguments for automation:
    - /DynamicUpdate Disable (prevents mid-upgrade hangs)
    - /Compat IgnoreWarning (bypasses compatibility warnings)
    - /ShowOOBE None (skips post-upgrade setup screens)
    - /quiet (minimizes UI interactions)

    Then exits, letting Windows Setup reboot and complete the upgrade.
#>

### ————— CONFIGURATION —————
# URL of your Win11 ISO (supply via -isoUrl or $env:isoUrl)
#$isoUrl     = "https://example.com/Windows11.iso"

# Where to save the ISO
$downloadDir = "$env:TEMP"
$isoPath     = Join-Path $downloadDir "Win11Upgrade.iso"

# Force upgrade flag - set to 1 to use /product server flag, 0 to skip it
if ([string]::IsNullOrEmpty($forceUpgrade)) {
    $forceUpgrade = 0
}

### ————— PROGRESS FUNCTION —————
function Show-Progress {
    param(
        [int]$Percent,
        [string]$Stage
    )
    if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
        Ninja-Property-Set windowsUpgradeProgress -Value $Percent
    } else {
        Write-Output "[$Stage] $Percent% complete"
    }
}

### ————— SCRIPT START —————
Show-Progress -Percent 0 -Stage "Start"

### ————— DISMOUNT ANY EXISTING ISOs —————
Write-Output "Checking for existing Windows 11 ISO..."
try {
    # Check if the ISO file we're about to download already exists and is mounted
    if (Test-Path $isoPath) {
        $diskImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        if ($null -ne $diskImage -and $diskImage.Attached) {
            Write-Output "Dismounting existing ISO: $isoPath"
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop
            Write-Output "ISO dismounted successfully"
        } else {
            Write-Output "ISO file exists but is not mounted"
        }
    } else {
        Write-Output "No existing ISO file found at $isoPath"
    }
} catch {
    Write-Output "Warning: Could not dismount ISO: $_"
}

### ————— ELEVATION CHECK —————
# RMM platforms run as SYSTEM (already elevated); when run manually without admin rights,
# relaunch elevated so the upgrade has the privileges it needs.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Relaunching elevated..."
    Start-Process -FilePath "PowerShell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

### ————— VALIDATE REQUIRED VARIABLES —————
if ([string]::IsNullOrWhiteSpace($isoUrl)) {
    Write-Error "CRITICAL: isoUrl variable is not set. This must be configured in your RMM or set manually."
    Show-Progress -Percent 0 -Stage "ConfigError"
    Stop-Transcript
    exit 1
}

### ————— PRE-FLIGHT CHECKS —————
Write-Output "Running pre-flight checks..."

# Check free disk space (need 20GB minimum for upgrade)
$systemDrive = $env:SystemDrive
$disk = Get-PSDrive -Name $systemDrive.TrimEnd(':')
$freeSpaceGB = [math]::Round($disk.Free / 1GB, 2)
Write-Output "Free disk space on ${systemDrive}: ${freeSpaceGB}GB"
if ($freeSpaceGB -lt 20) {
    Write-Error "CRITICAL: Insufficient disk space. ${freeSpaceGB}GB free, but 20GB minimum required for upgrade."
    Show-Progress -Percent 0 -Stage "InsufficientDiskSpace"
    Stop-Transcript
    exit 1
}

# Check for pending reboots
$pendingReboot = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
if ($pendingReboot) {
    Write-Warning "WARNING: Pending reboot detected. This may interfere with upgrade. Consider rebooting first."
}

# Clean temporary files to free up space
Write-Output "Cleaning temporary files to free up disk space..."
try {
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "Temporary files cleaned successfully"
} catch {
    Write-Output "Warning: Could not clean all temporary files: $_"
}

### ————— DOWNLOAD ISO (Using BITS for speed + compatibility) —————
Show-Progress -Percent 25 -Stage "Downloading"
Write-Output "Downloading ISO from $isoUrl..."

try {
    Start-BitsTransfer -Source $isoUrl -Destination $isoPath -DisplayName "Windows ISO Download" -ErrorAction Stop
} catch {
    Write-Error "Download failed: $_"
    Show-Progress -Percent 0 -Stage "DownloadFailed"
    exit 1
}



### ————— MOUNT ISO —————
Write-Output "Mounting ISO..."
try {
    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 5
    $vol = $diskImage | Get-Volume
    $driveLetter = "$($vol.DriveLetter):"
} catch {
    Write-Error "Mount failed: $_"
    Show-Progress -Percent 0 -Stage "MountFailed"
    exit 1
}
Show-Progress -Percent 50 -Stage "DownloadedAndMounted"

### ————— LAUNCH SETUP —————
Show-Progress -Percent 75 -Stage "SetupStart"

# Build comprehensive argument list for fully automated upgrade
$setupArgs = @(
    "/auto Upgrade",                # Automated upgrade mode
    "/eula accept",                 # Accept EULA automatically
    "/quiet",                       # Minimize UI interactions
    "/DynamicUpdate Disable",       # Prevent downloading updates during setup (common hang point)
    "/Compat IgnoreWarning",        # Bypass compatibility warnings
    "/ShowOOBE None",               # Skip Out-of-Box Experience after upgrade
    "/Telemetry Enable"             # Enable telemetry (sometimes required for upgrade)
)

# Add /product server flag if force upgrade is enabled
if ($forceUpgrade -eq 1) {
    $setupArgs += "/product server"
    Write-Output "Launching Windows 11 setup with /product server flag (fully automated)..."
} else {
    Write-Output "Launching Windows 11 setup (fully automated)..."
}

Write-Output "Setup arguments: $($setupArgs -join ' ')"

# Launch setup.exe with high priority and hidden window
try {
    $setupProcess = Start-Process `
        -FilePath "$driveLetter\setup.exe" `
        -ArgumentList $setupArgs `
        -WindowStyle Hidden `
        -PassThru `
        -ErrorAction Stop

    # Wait 10 seconds to confirm setup process started successfully
    Start-Sleep -Seconds 10

    if ($setupProcess.HasExited) {
        Write-Error "CRITICAL: Setup.exe exited prematurely (Exit Code: $($setupProcess.ExitCode)). Check logs for details."
        Show-Progress -Percent 0 -Stage "SetupFailed"
        Stop-Transcript
        exit 1
    } else {
        Write-Output "Setup process confirmed running (PID: $($setupProcess.Id))"
        Write-Output "Setup launched successfully; the machine will reboot and complete the upgrade."
    }
} catch {
    Write-Error "Failed to launch setup.exe: $_"
    Show-Progress -Percent 0 -Stage "SetupLaunchFailed"
    Stop-Transcript
    exit 1
}

# script ends here; Setup handles reboot & ISO cleanup

Stop-Transcript
