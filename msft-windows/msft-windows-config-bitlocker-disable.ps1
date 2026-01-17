## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1

# This script disables BitLocker encryption:
# - Checks for BitLocker availability
# - Disables BitLocker on all non-OS volumes first
# - Disables BitLocker on OS volume last
# - Starts decryption and exits (decryption continues in background)
# - Does NOT remove BitLocker feature/service
# Use Case: Prepare machine for imaging, hardware changes, or decommissioning

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-config-bitlocker-disable.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials"
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
        $Description = "RMM-initiated BitLocker disable"
    }
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== BitLocker Disable ===" -ForegroundColor Cyan
Write-Host ""

# Check Windows edition
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$supportsBitLocker = $osInfo.Caption -match "Pro|Enterprise|Education"

if (!$supportsBitLocker) {
    Write-Host "WARNING: BitLocker not typically available on this Windows edition" -ForegroundColor Yellow
    Write-Host "Current Edition: $($osInfo.Caption)" -ForegroundColor Yellow
    Write-Host "Continuing anyway to check for any encrypted volumes..." -ForegroundColor Yellow
    Write-Host ""
}

try {
    # Get all BitLocker-protected volumes
    Write-Host "Checking for BitLocker-protected volumes..." -ForegroundColor Yellow
    $volumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' -or $_.VolumeStatus -ne 'FullyDecrypted' }

    if (!$volumes -or $volumes.Count -eq 0) {
        Write-Host "No BitLocker-protected volumes found." -ForegroundColor Green
        Write-Host ""
        Write-Host "=== BitLocker Disable Complete ===" -ForegroundColor Cyan
        Write-Host "No action required." -ForegroundColor Gray
        Stop-Transcript
        exit 0
    }

    Write-Host "Found $($volumes.Count) volume(s) with BitLocker protection or encryption" -ForegroundColor Gray
    Write-Host ""

    # Separate the OS volume from other volumes
    $osVolume = $volumes | Where-Object { $_.VolumeType -eq "OperatingSystem" }
    $nonOsVolumes = $volumes | Where-Object { $_.VolumeType -ne "OperatingSystem" }

    # Track results
    $decryptionStarted = @()
    $alreadyDecrypting = @()
    $errors = @()

    # Disable BitLocker on all non-OS volumes first
    if ($nonOsVolumes) {
        Write-Host "--- Processing Non-OS Volumes ---" -ForegroundColor Yellow
        foreach ($volume in $nonOsVolumes) {
            Write-Host "Processing volume: $($volume.MountPoint)" -ForegroundColor Cyan
            Write-Host "  Current Status: $($volume.VolumeStatus)" -ForegroundColor Gray
            Write-Host "  Protection: $($volume.ProtectionStatus)" -ForegroundColor Gray

            try {
                if ($volume.VolumeStatus -eq 'DecryptionInProgress') {
                    Write-Host "  Decryption already in progress" -ForegroundColor Yellow
                    $alreadyDecrypting += $volume.MountPoint
                } elseif ($volume.VolumeStatus -eq 'FullyDecrypted') {
                    Write-Host "  Already fully decrypted" -ForegroundColor Green
                } else {
                    Disable-BitLocker -MountPoint $volume.MountPoint -ErrorAction Stop
                    Write-Host "  BitLocker disable initiated" -ForegroundColor Green
                    $decryptionStarted += $volume.MountPoint
                }
            } catch {
                Write-Host "  ERROR: $_" -ForegroundColor Red
                $errors += "$($volume.MountPoint): $_"
            }
            Write-Host ""
        }
    }

    # Disable BitLocker on OS volume last
    if ($osVolume) {
        Write-Host "--- Processing OS Volume ---" -ForegroundColor Yellow
        Write-Host "Processing volume: $($osVolume.MountPoint)" -ForegroundColor Cyan
        Write-Host "  Current Status: $($osVolume.VolumeStatus)" -ForegroundColor Gray
        Write-Host "  Protection: $($osVolume.ProtectionStatus)" -ForegroundColor Gray

        try {
            if ($osVolume.VolumeStatus -eq 'DecryptionInProgress') {
                Write-Host "  Decryption already in progress" -ForegroundColor Yellow
                $alreadyDecrypting += $osVolume.MountPoint
            } elseif ($osVolume.VolumeStatus -eq 'FullyDecrypted') {
                Write-Host "  Already fully decrypted" -ForegroundColor Green
            } else {
                Disable-BitLocker -MountPoint $osVolume.MountPoint -ErrorAction Stop
                Write-Host "  BitLocker disable initiated" -ForegroundColor Green
                $decryptionStarted += $osVolume.MountPoint
            }
        } catch {
            Write-Host "  ERROR: $_" -ForegroundColor Red
            $errors += "$($osVolume.MountPoint): $_"
        }
        Write-Host ""
    }

    # Summary
    Write-Host "=== BitLocker Disable Summary ===" -ForegroundColor Cyan

    if ($decryptionStarted.Count -gt 0) {
        Write-Host "Decryption started on:" -ForegroundColor Green
        foreach ($mount in $decryptionStarted) {
            Write-Host "  - $mount" -ForegroundColor Green
        }
    }

    if ($alreadyDecrypting.Count -gt 0) {
        Write-Host "Already decrypting:" -ForegroundColor Yellow
        foreach ($mount in $alreadyDecrypting) {
            Write-Host "  - $mount" -ForegroundColor Yellow
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host "Errors:" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($decryptionStarted.Count -gt 0 -or $alreadyDecrypting.Count -gt 0) {
        Write-Host "NOTE: Decryption is running in the background." -ForegroundColor Yellow
        Write-Host "This process can take several hours depending on drive size." -ForegroundColor Yellow
        Write-Host "Monitor progress with: Get-BitLockerVolume" -ForegroundColor Cyan
        Write-Host ""
    }

    Write-Host "=== BitLocker Disable Complete ===" -ForegroundColor Cyan

    if ($errors.Count -gt 0) {
        Stop-Transcript
        exit 1
    }

} catch {
    Write-Host "Error disabling BitLocker: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Stop-Transcript
