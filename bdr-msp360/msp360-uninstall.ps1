## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $Description

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

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msp360-uninstall.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
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
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "MSP360 Uninstall"
    }
}

# Start the script logic here.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

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
    Stop-Transcript
    exit 0
}

# Get uninstall string
$uninstallString = $app.UninstallString

if (-not $uninstallString) {
    Write-Log "No uninstall string found for $($app.DisplayName)" "ERROR"
    Stop-Transcript
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
    # EXE-based uninstaller - handle paths with spaces by checking for quoted path first
    if ($uninstallString -match '^"([^"]+)"\s*(.*)$') {
        # Quoted path: "C:\Program Files\App\uninstall.exe" /args
        $uninstallCommand = $matches[1]
        $existingArgs = $matches[2]
    } elseif ($uninstallString -match '^([^"\s]+\.exe)\s*(.*)$') {
        # Unquoted path without spaces: C:\App\uninstall.exe /args
        $uninstallCommand = $matches[1]
        $existingArgs = $matches[2]
    } else {
        # Fallback: treat entire string as command
        $uninstallCommand = $uninstallString -replace '"', ''
        $existingArgs = ""
    }

    # Add silent flags if not already present
    if ($existingArgs -notmatch "/S|/silent|/quiet") {
        $uninstallArgs = "$existingArgs /S /silent".Trim()
    } else {
        $uninstallArgs = $existingArgs
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

        Stop-Transcript
        exit 0
    } else {
        Write-Log "Uninstall completed with exit code: $($process.ExitCode)" "WARNING"
        Stop-Transcript
        exit $process.ExitCode
    }
} catch {
    Write-Log "Error during uninstallation: $($_.Exception.Message)" "ERROR"
    Stop-Transcript
    exit 1
}
