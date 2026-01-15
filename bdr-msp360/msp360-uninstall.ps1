<#
.SYNOPSIS
    Uninstalls DTCBSure Cloud Backup (MSP360)
.DESCRIPTION
    This script locates and uninstalls MSP360 backup software branded as "DTCBSure Cloud Backup"
    by searching the Windows Registry and executing the uninstall command.
.NOTES
    Author: Nathaniel Smith / DTC
    Date: 2025-12-01
    Compatible with: Windows 7+
#>

# Set error action preference
$ErrorActionPreference = 'Stop'

# Function to write log messages
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# Registry paths to search for uninstall information
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

Write-Log "Starting MSP360 (DTCBSure Cloud Backup) uninstall process"

# Search for the application
$app = $null
foreach ($path in $registryPaths) {
    Write-Log "Searching in: $path"
    $app = Get-ItemProperty $path -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "*DTCBSure Cloud Backup*" -or
                         $_.DisplayName -like "*MSP360*" -or
                         $_.DisplayName -like "*CloudBerry*" }

    if ($app) {
        Write-Log "Found application: $($app.DisplayName)"
        break
    }
}

if (-not $app) {
    Write-Log "DTCBSure Cloud Backup / MSP360 is not installed on this system" "WARNING"
    exit 0
}

# Get uninstall string
$uninstallString = $app.UninstallString

if (-not $uninstallString) {
    Write-Log "No uninstall string found for $($app.DisplayName)" "ERROR"
    exit 1
}

Write-Log "Uninstall string found: $uninstallString"

# Prepare the uninstall command
# MSP360 typically uses an MSI installer, so we need to handle both MSI and EXE uninstallers
if ($uninstallString -match "msiexec") {
    # MSI-based uninstaller
    $productCode = $uninstallString -replace ".*({[A-F0-9\-]+}).*", '$1'
    $uninstallCommand = "msiexec.exe"
    $uninstallArgs = "/x $productCode /qn /norestart"
    Write-Log "Detected MSI installer. Product Code: $productCode"
} else {
    # EXE-based uninstaller
    # Extract the executable path (remove quotes if present)
    $exePath = $uninstallString -replace '"', ''

    # Check if there are already arguments in the uninstall string
    if ($exePath -match '^(.*\.exe)\s+(.*)$') {
        $uninstallCommand = $matches[1]
        $existingArgs = $matches[2]
        # Add silent flags if not already present
        if ($existingArgs -notmatch "/S|/silent|/quiet") {
            $uninstallArgs = "$existingArgs /S /silent"
        } else {
            $uninstallArgs = $existingArgs
        }
    } else {
        $uninstallCommand = $exePath
        $uninstallArgs = "/S /silent"
    }
    Write-Log "Detected EXE installer"
}

Write-Log "Executing uninstall command: $uninstallCommand $uninstallArgs"

try {
    # Execute the uninstall
    $process = Start-Process -FilePath $uninstallCommand -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "Uninstall completed successfully. Exit code: $($process.ExitCode)"

        # Exit code 3010 means reboot required
        if ($process.ExitCode -eq 3010) {
            Write-Log "A reboot is required to complete the uninstallation" "WARNING"
        }

        exit 0
    } else {
        Write-Log "Uninstall completed with exit code: $($process.ExitCode)" "WARNING"
        exit $process.ExitCode
    }
} catch {
    Write-Log "Error during uninstallation: $($_.Exception.Message)" "ERROR"
    exit 1
}
