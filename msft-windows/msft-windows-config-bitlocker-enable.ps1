## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $EncryptDataDrives = $true    # Also encrypt fixed data drives
## $UseUsedSpaceOnly = $true     # Faster encryption, only encrypts used space
## $RMMRecoveryPasswordField = "bitlockerRecoveryPassword"  # RMM custom field name for all recovery passwords
## $RMMBitlockerStatusField = "bitlockerStatus"             # RMM custom field name for BitLocker status

# This script enables BitLocker encryption:
# - Checks for TPM 2.0 (exits gracefully if not present)
# - Configures TPM PCR validation profile (PCR 7 + 11 only for UEFI)
# - Enables BitLocker on OS drive with TPM protector
# - Adds recovery password protector
# - Optionally encrypts data drives with auto-unlock
# - Saves recovery keys to local file and RMM custom field (all drives in one field)
# Use Case: Deploy via RMM for workstation encryption

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-config-bitlocker-enable.log"

# Default values
if ($null -eq $EncryptDataDrives) { $EncryptDataDrives = $true }
if ($null -eq $UseUsedSpaceOnly) { $UseUsedSpaceOnly = $true }
if ($null -eq $RMMRecoveryPasswordField) { $RMMRecoveryPasswordField = "bitlockerRecoveryPassword" }
if ($null -eq $RMMBitlockerStatusField) { $RMMBitlockerStatusField = "bitlockerStatus" }

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
$tpm = Get-CimInstance -Namespace "Root\CIMv2\Security\MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction SilentlyContinue

if (!$tpm -or !$tpm.IsEnabled_InitialValue) {
    Write-Host "TPM not found or not enabled. Skipping BitLocker configuration." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

Write-Host "TPM Status: Enabled and ready" -ForegroundColor Green

# Configure TPM PCR validation profile for UEFI (PCR 7 + 11 only)
# PCR 7 = Secure Boot state, PCR 11 = BitLocker access control
# This reduces false recovery events from firmware updates while maintaining security
# Equivalent GP: Computer Config > Admin Templates > Windows Components > BitLocker > OS Drives >
#   "Configure TPM platform validation profile for native UEFI firmware configurations"
$pcrRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\FVE\OSPlatformValidation_UEFI"
if (!(Test-Path $pcrRegPath)) {
    New-Item -Path $pcrRegPath -Force | Out-Null
}
# Enable the policy
Set-ItemProperty -Path $pcrRegPath -Name "Enabled" -Value 1 -Type DWord
# Disable all PCRs, then enable only 7 and 11
for ($i = 0; $i -le 23; $i++) {
    Set-ItemProperty -Path $pcrRegPath -Name "$i" -Value 0 -Type DWord
}
Set-ItemProperty -Path $pcrRegPath -Name "7" -Value 1 -Type DWord
Set-ItemProperty -Path $pcrRegPath -Name "11" -Value 1 -Type DWord
Write-Host "PCR validation profile configured: PCR 7 (Secure Boot) + PCR 11 (BitLocker)" -ForegroundColor Green

$recoveryKeyPath = "$ENV:WINDIR\temp"
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

# Restrict file permissions to Administrators and SYSTEM only
$fileAcl = Get-Acl $recoveryFile
$fileAcl.SetAccessRuleProtection($true, $false)  # Disable inheritance
foreach ($rule in @($fileAcl.Access)) { $fileAcl.RemoveAccessRule($rule) | Out-Null }
$fileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")))
$fileAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")))
Set-Acl -Path $recoveryFile -AclObject $fileAcl
Write-Host "Recovery file permissions restricted to Administrators and SYSTEM" -ForegroundColor Gray

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
                $driveLetter = $vol.MountPoint[0]
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

    # Attempt to backup recovery keys to Active Directory (if domain-joined)
    Write-Host ""
    Write-Host "Checking for Active Directory backup..." -ForegroundColor Yellow
    try {
        $computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($computerInfo.PartOfDomain) {
            Write-Host "Computer is domain-joined. Attempting to backup recovery keys to AD..." -ForegroundColor Gray

            # Backup OS drive recovery key to AD
            $osVolume = Get-BitLockerVolume -MountPoint $osDrive.MountPoint
            foreach ($keyProtector in $osVolume.KeyProtector) {
                if ($keyProtector.KeyProtectorType -eq 'RecoveryPassword') {
                    try {
                        Backup-BitLockerKeyProtector -MountPoint $osDrive.MountPoint -KeyProtectorId $keyProtector.KeyProtectorId -ErrorAction Stop
                        Write-Host "  OS drive recovery key backed up to Active Directory" -ForegroundColor Green
                    } catch {
                        Write-Host "  Warning: Could not backup OS drive to AD: $_" -ForegroundColor Yellow
                    }
                }
            }

            # Backup data drive recovery keys to AD
            if ($EncryptDataDrives -and $dataVolumes) {
                foreach ($volume in $dataVolumes) {
                    $dataVol = Get-BitLockerVolume -MountPoint $volume.MountPoint
                    foreach ($keyProtector in $dataVol.KeyProtector) {
                        if ($keyProtector.KeyProtectorType -eq 'RecoveryPassword') {
                            try {
                                Backup-BitLockerKeyProtector -MountPoint $volume.MountPoint -KeyProtectorId $keyProtector.KeyProtectorId -ErrorAction Stop
                                Write-Host "  $($volume.MountPoint) recovery key backed up to Active Directory" -ForegroundColor Green
                            } catch {
                                Write-Host "  Warning: Could not backup $($volume.MountPoint) to AD: $_" -ForegroundColor Yellow
                            }
                        }
                    }
                }
            }
        } else {
            Write-Host "Computer is not domain-joined. Skipping AD backup." -ForegroundColor Gray
        }
    } catch {
        Write-Host "Could not determine domain status: $_" -ForegroundColor Yellow
    }

    # Output all recovery passwords to single RMM custom field
    if ($RMM -eq 1) {
        Write-Host ""
        Write-Host "=== RMM Recovery Output ===" -ForegroundColor Cyan

        # Collect recovery passwords from all encrypted drives
        $recoveryEntries = @()
        $allVolumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq "On" -or $_.VolumeStatus -ne "FullyDecrypted" }

        foreach ($vol in $allVolumes) {
            $keyProtector = $vol.KeyProtector |
                Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                Select-Object -First 1

            if ($keyProtector) {
                $recoveryEntries += "$($vol.MountPoint) $($keyProtector.RecoveryPassword)"
            }
        }

        $recoveryFieldValue = $recoveryEntries -join " | "
        Write-Host "Recovery field value: $recoveryFieldValue"

        # Build status field (all drives, not just encrypted ones)
        $statusEntries = @()
        foreach ($vol in (Get-BitLockerVolume)) {
            $encStatus = if ($vol.VolumeStatus -ne "FullyDecrypted") { "Encrypted" } else { "Not Encrypted" }
            $statusEntries += "$($vol.MountPoint) $encStatus"
        }
        $statusFieldValue = $statusEntries -join " | "
        Write-Host "Status field value: $statusFieldValue"

        # Try NinjaRMM first
        $ninjaCmd = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
        if ($ninjaCmd) {
            if ($recoveryFieldValue) {
                Ninja-Property-Set $RMMRecoveryPasswordField "$recoveryFieldValue"
                Write-Host "NinjaRMM: Set $RMMRecoveryPasswordField" -ForegroundColor Green
            }
            Ninja-Property-Set $RMMBitlockerStatusField "$statusFieldValue"
            Write-Host "NinjaRMM: Set $RMMBitlockerStatusField" -ForegroundColor Green
        } else {
            # Generic RMM output - recovery info in parseable format for any RMM
            Write-Host "BITLOCKER_RECOVERY_PASSWORDS=$recoveryFieldValue"
            Write-Host "BITLOCKER_STATUS=$statusFieldValue"
        }
    }

    Write-Host ""
    Write-Host "=== BitLocker Configuration Complete ===" -ForegroundColor Cyan
    Write-Host "Recovery keys saved to: $recoveryFile" -ForegroundColor Yellow
    Write-Host "File permissions: Administrators and SYSTEM only" -ForegroundColor Gray
    Write-Host ""
    Write-Host "IMPORTANT: Recovery file at $recoveryFile should be collected and securely deleted." -ForegroundColor Yellow
    Write-Host "Without recovery keys, encrypted drives CANNOT be unlocked if TPM fails." -ForegroundColor Red

} catch {
    Write-Host "Error configuring BitLocker: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Stop-Transcript
