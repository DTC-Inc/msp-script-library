## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $EncryptDataDrives = $true    # Also encrypt fixed data drives
## $UseUsedSpaceOnly = $true     # Faster encryption, only encrypts used space

# This script enables BitLocker encryption:
# - Checks for TPM 2.0
# - Enables BitLocker on OS drive with TPM protector
# - Adds recovery password protector
# - Optionally encrypts data drives with auto-unlock
# - Saves recovery keys to local file (for RMM collection)
# Use Case: Deploy via RMM for workstation encryption

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-config-bitlocker-enable.log"

# Default values
if ($null -eq $EncryptDataDrives) { $EncryptDataDrives = $true }
if ($null -eq $UseUsedSpaceOnly) { $UseUsedSpaceOnly = $true }

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
        $Description = "RMM-initiated BitLocker configuration"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== BitLocker Configuration ===" -ForegroundColor Cyan
Write-Host "Options:" -ForegroundColor Yellow
Write-Host "  Encrypt Data Drives: $EncryptDataDrives"
Write-Host "  Used Space Only: $UseUsedSpaceOnly"
Write-Host ""

# Check Windows edition
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$supportsBitLocker = $osInfo.Caption -match "Pro|Enterprise|Education"

if (!$supportsBitLocker) {
    Write-Host "ERROR: BitLocker not supported on this Windows edition" -ForegroundColor Red
    Write-Host "Current Edition: $($osInfo.Caption)" -ForegroundColor Yellow
    Write-Host "BitLocker requires Windows Pro, Enterprise, or Education" -ForegroundColor Yellow
    Stop-Transcript
    exit 1
}

Write-Host "Windows Edition: $($osInfo.Caption)" -ForegroundColor Green

# Check for TPM
$tpm = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue

if (!$tpm -or !$tpm.IsEnabled_InitialValue) {
    Write-Host "ERROR: TPM not found or not enabled" -ForegroundColor Red
    Write-Host "BitLocker requires a TPM 2.0 chip for automatic encryption" -ForegroundColor Yellow
    Stop-Transcript
    exit 1
}

Write-Host "TPM Status: Enabled and ready" -ForegroundColor Green

# Create recovery key directory
$recoveryKeyPath = "$env:SystemDrive\BitLocker-Recovery-Keys"
if (!(Test-Path $recoveryKeyPath)) {
    New-Item -Path $recoveryKeyPath -ItemType Directory -Force | Out-Null
}
$recoveryFile = Join-Path $recoveryKeyPath "BitLocker-Recovery-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').txt"

# Initialize recovery file
$header = @"
========================================
BitLocker Recovery Information
========================================
Computer: $env:COMPUTERNAME
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

IMPORTANT: Store this file securely!
These recovery keys are required to unlock
encrypted drives if TPM fails.
========================================

"@
$header | Out-File -FilePath $recoveryFile -Encoding UTF8

try {
    # Enable BitLocker on OS drive
    $osDrive = Get-BitLockerVolume | Where-Object { $_.VolumeType -eq "OperatingSystem" }

    if ($osDrive.ProtectionStatus -eq "Off") {
        Write-Host "Enabling BitLocker on OS drive ($($osDrive.MountPoint))..." -ForegroundColor Yellow

        # Build encryption parameters
        $encryptParams = @{
            MountPoint = $osDrive.MountPoint
            TpmProtector = $true
            EncryptionMethod = "XtsAes256"
            SkipHardwareTest = $true
        }

        if ($UseUsedSpaceOnly) {
            $encryptParams.Add("UsedSpaceOnly", $true)
        }

        # Enable BitLocker
        Enable-BitLocker @encryptParams

        # Add recovery password protector
        Add-BitLockerKeyProtector -MountPoint $osDrive.MountPoint -RecoveryPasswordProtector

        # Get recovery password
        $recoveryPassword = (Get-BitLockerVolume -MountPoint $osDrive.MountPoint).KeyProtector |
                           Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                           Select-Object -First 1 -ExpandProperty RecoveryPassword

        # Save to file
        $osOutput = @"
OS DRIVE ($($osDrive.MountPoint))
Recovery Password: $recoveryPassword
Encryption Method: XtsAes256
Protection Status: Enabled

"@
        $osOutput | Out-File -FilePath $recoveryFile -Append -Encoding UTF8

        Write-Host "BitLocker enabled on OS drive" -ForegroundColor Green
        Write-Host "Recovery password saved to: $recoveryFile" -ForegroundColor Cyan

    } else {
        Write-Host "BitLocker already enabled on OS drive" -ForegroundColor Green

        # Still get the recovery key for documentation
        $recoveryPassword = (Get-BitLockerVolume -MountPoint $osDrive.MountPoint).KeyProtector |
                           Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                           Select-Object -First 1 -ExpandProperty RecoveryPassword

        if ($recoveryPassword) {
            $osOutput = @"
OS DRIVE ($($osDrive.MountPoint)) - ALREADY ENCRYPTED
Recovery Password: $recoveryPassword

"@
            $osOutput | Out-File -FilePath $recoveryFile -Append -Encoding UTF8
        }
    }

    # Encrypt data drives if requested
    if ($EncryptDataDrives) {
        Write-Host ""
        Write-Host "Checking data drives..." -ForegroundColor Yellow

        $allDataVolumes = Get-BitLockerVolume | Where-Object { $_.VolumeType -eq "Data" }
        $dataVolumes = @()

        # Filter out external/USB drives
        foreach ($vol in $allDataVolumes) {
            try {
                $driveLetter = $vol.MountPoint.TrimEnd(':').TrimEnd('\')
                $partition = Get-Partition | Where-Object { $_.DriveLetter -eq $driveLetter } | Select-Object -First 1

                if ($partition) {
                    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction SilentlyContinue

                    # Skip USB, SD, MMC drives
                    if ($disk.BusType -in @('USB', 'SD', 'MMC')) {
                        Write-Host "Skipping external drive $($vol.MountPoint) (BusType: $($disk.BusType))" -ForegroundColor Gray
                        continue
                    }

                    $dataVolumes += $vol
                }
            } catch {
                Write-Host "Could not determine drive type for $($vol.MountPoint): $_" -ForegroundColor Yellow
                # Include if we can't determine - better than skipping internal drives
                $dataVolumes += $vol
            }
        }

        Write-Host "Found $($dataVolumes.Count) internal data volume(s)" -ForegroundColor Gray

        foreach ($volume in $dataVolumes) {
            if ($volume.ProtectionStatus -eq "Off") {
                Write-Host "Enabling BitLocker on $($volume.MountPoint)..." -ForegroundColor Yellow

                # Build encryption parameters
                $dataEncryptParams = @{
                    MountPoint = $volume.MountPoint
                    RecoveryPasswordProtector = $true
                    EncryptionMethod = "XtsAes256"
                    SkipHardwareTest = $true
                }

                if ($UseUsedSpaceOnly) {
                    $dataEncryptParams.Add("UsedSpaceOnly", $true)
                }

                Enable-BitLocker @dataEncryptParams

                # Enable auto-unlock
                Enable-BitLockerAutoUnlock -MountPoint $volume.MountPoint

                # Get recovery password
                $dataRecoveryPassword = (Get-BitLockerVolume -MountPoint $volume.MountPoint).KeyProtector |
                                       Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                                       Select-Object -First 1 -ExpandProperty RecoveryPassword

                $dataOutput = @"
DATA DRIVE ($($volume.MountPoint))
Recovery Password: $dataRecoveryPassword
Auto-Unlock: Enabled
Encryption Method: XtsAes256

"@
                $dataOutput | Out-File -FilePath $recoveryFile -Append -Encoding UTF8

                Write-Host "BitLocker enabled on $($volume.MountPoint) with auto-unlock" -ForegroundColor Green
            } else {
                Write-Host "$($volume.MountPoint) already encrypted" -ForegroundColor Gray
            }
        }
    }

    Write-Host ""
    Write-Host "=== BitLocker Configuration Complete ===" -ForegroundColor Cyan
    Write-Host "Recovery keys saved to: $recoveryFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "IMPORTANT: Collect this file via RMM and store securely!" -ForegroundColor Red
    Write-Host "Path: $recoveryFile" -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Cyan

} catch {
    Write-Host "Error configuring BitLocker: $_" -ForegroundColor Red
    exit 1
}

Stop-Transcript
