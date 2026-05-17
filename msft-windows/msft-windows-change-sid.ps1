## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $Description - Ticket number and/or initials for audit trail

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-change-sid.log"
$sidchgDownloadURL = "https://f002.backblazeb2.com/file/public-dtc/repo/tools/win/sidchg64-3.0n.exe"
$sidchgPath = "$ENV:WINDIR\temp\sidchg64.exe"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        Write-Host "Downloading sidchg from B2 bucket..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $sidchgDownloadURL -OutFile $sidchgPath -UseBasicParsing
            Write-Host "Download successful: $sidchgPath" -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Failed to download sidchg." -ForegroundColor Red
            Write-Host "Error details: $_" -ForegroundColor Red
            exit 1
        }

        # Confirm the action
        Write-Host "`nWARNING: Changing the computer SID will require a reboot." -ForegroundColor Yellow
        Write-Host "This operation should only be performed on cloned systems or when specifically required." -ForegroundColor Yellow
        $confirmation = Read-Host "`nAre you sure you want to change the computer SID? (yes/no)"

        if ($confirmation -eq "yes") {
            $Description = Read-Host "Please enter the ticket # and/or your initials for the audit trail"
            if ($Description) {
                $ValidInput = 1
            } else {
                Write-Host "Description is required. Please try again." -ForegroundColor Red
            }
        } else {
            Write-Host "Operation cancelled by user." -ForegroundColor Yellow
            exit 0
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
        $Description = "Automatic SID change via RMM"
    }

    # Auto-download from B2
    Write-Host "Downloading sidchg from B2 bucket..."
    try {
        Invoke-WebRequest -Uri $sidchgDownloadURL -OutFile $sidchgPath -UseBasicParsing
        Write-Host "Download successful: $sidchgPath" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to download sidchg." -ForegroundColor Red
        Write-Host "Error details: $_" -ForegroundColor Red
        exit 1
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "sidchg path: $sidchgPath"
Write-Host ""

# Verify administrative privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run with administrative privileges." -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Write-Host "Administrative privileges confirmed." -ForegroundColor Green

# Get current SID for logging
try {
    $currentSID = (Get-WmiObject -Class Win32_ComputerSystem).Domain
    $machineSID = (Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount='True'" | Select-Object -First 1).SID
    if ($machineSID) {
        # Extract machine SID (remove RID at the end)
        $machineSIDParts = $machineSID.Split('-')
        $currentMachineSID = $machineSIDParts[0..($machineSIDParts.Length - 2)] -join '-'
        Write-Host "Current Machine SID: $currentMachineSID"
    }
} catch {
    Write-Host "Warning: Could not retrieve current SID for logging. Continuing anyway..." -ForegroundColor Yellow
}

# Execute sidchg to change the SID
Write-Host "`nExecuting sidchg to change computer SID..." -ForegroundColor Cyan

try {
    # Run sidchg with /F flag to force SID change
    # Note: sidchg will automatically trigger a reboot after successful execution
    $process = Start-Process -FilePath $sidchgPath -ArgumentList "/F" -Wait -NoNewWindow -PassThru

    $exitCode = $process.ExitCode
    Write-Host "sidchg exit code: $exitCode"

    if ($exitCode -eq 0) {
        Write-Host "`nSID change completed successfully." -ForegroundColor Green
        Write-Host "The system will reboot to apply the new SID." -ForegroundColor Yellow
        Write-Host "After reboot, verify the new SID has been applied." -ForegroundColor Yellow
    } else {
        Write-Host "`nWARNING: sidchg exited with code $exitCode" -ForegroundColor Yellow
        Write-Host "Please check the sidchg documentation for exit code meanings." -ForegroundColor Yellow
        Write-Host "The system may still reboot to apply changes." -ForegroundColor Yellow
    }

} catch {
    Write-Host "`nERROR: Failed to execute sidchg." -ForegroundColor Red
    Write-Host "Error details: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Write-Host "`nScript execution completed. Check transcript for full details."

Stop-Transcript
