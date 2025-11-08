## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $isoUrl
## $forceUpgrade

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-win11-upgrade.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else { 
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
        
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
        
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }   


    
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

<#
.SYNOPSIS
    Quiet in-place upgrade Win10 → Win11 with staged NinjaRMM (or host) progress.

.DESCRIPTION
    Reports progress at 0 %, 25 %, 50 %, 75 %:
      0 % – script start
      25 % – download beginning
      50 % – download finished & ISO mounted
      75 % – setup.exe launched
    Then exits, letting Windows Setup reboot and complete the upgrade.
#>

### ————— CONFIGURATION —————
# $true = report to NinjaRMM; $false = write to host
#$RMM        = $true

# URL of your Win11 ISO
#$isoUrl     = "https://example.com/Windows11.iso"

# Where to save the ISO
$downloadDir = "$env:TEMP"
$isoPath     = Join-Path $downloadDir "Win11Upgrade.iso"

# Force upgrade flag - set to 1 to use /product server flag, 0 to skip it
if ($null -eq $forceUpgrade) {
    $forceUpgrade = 0
}

### ————— PROGRESS FUNCTION —————
function Show-Progress {
    param(
        [int]$Percent,
        [string]$Stage
    )
    if ($RMM) {
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

### ————— ELEVATION CHECK (Interactive mode only) —————
# Skip elevation check when running from RMM - RMM platforms run as SYSTEM (already elevated)
if ($RMM -ne 1) {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output "Relaunching elevated..."
        Start-Process -FilePath "PowerShell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs
        exit
    }
}

### ————— VALIDATE REQUIRED VARIABLES —————
if ([string]::IsNullOrWhiteSpace($isoUrl)) {
    Write-Error "CRITICAL: isoUrl variable is not set. This must be configured in your RMM or set manually."
    Show-Progress -Percent 0 -Stage "ConfigError"
    Stop-Transcript
    exit 1
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

# Build argument list based on forceUpgrade flag
$setupArgs = @("/auto Upgrade", "/eula accept")
if ($forceUpgrade -eq 1) {
    $setupArgs += "/product server"
    Write-Output "Launching Windows 11 setup (quiet, no reboot) with /product server flag..."
} else {
    Write-Output "Launching Windows 11 setup (quiet, no reboot)..."
}

Start-Process `
    -FilePath "$driveLetter\setup.exe" `
    -ArgumentList $setupArgs

Write-Output "Setup launched; the machine will reboot and complete the upgrade."
# script ends here; Setup handles reboot & ISO cleanup

Stop-Transcript
