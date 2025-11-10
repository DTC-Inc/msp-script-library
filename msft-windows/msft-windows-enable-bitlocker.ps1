## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $Description

### ————— MSP RMM VARIABLE INITIALIZATION GOES HERE —————
# Example for NinjaRMM:
# $RMM = 1
# $Description = Ninja custom field or automatic
#
# Example for ConnectWise Automate:
# $RMM = 1
# $Description = %description%
#
# Example for Datto RMM:
# $RMM = 1
# $Description = $env:description
### ————— END RMM VARIABLE INITIALIZATION —————

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-enable-bitlocker.log"

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
    Enables BitLocker with TPM on OS volume and auto-unlock on data volumes.

.DESCRIPTION
    This script enables BitLocker encryption on all fixed drives with the following features:

    Features:
    - Validates TPM presence and readiness before attempting encryption
    - Enables BitLocker using TPM on OS volume for automatic unlock (no user interaction at boot)
    - Enables BitLocker with automatic unlock on data volumes (unlocked when OS boots)
    - Automatically creates BOTH recovery passwords (48-digit) AND recovery keys (.BEK) for ALL volumes
    - Backs up BOTH passwords and keys to Active Directory (domain-joined systems)
    - Stores recovery passwords in RMM custom fields for quick access
    - Configures registry settings for automatic AD backup (domain-joined systems)
    - Provides clear, user-friendly output showing status of each volume
    - Generates summary report of actions taken

    TPM Requirements:
    - TPM 1.2 or 2.0 must be present and enabled in BIOS/UEFI
    - TPM must be ready (initialized and owned)
    - If no TPM is available, script exits without enabling BitLocker

    Encryption Strategy:
    - OS Volume: TPM protector (automatic unlock at boot)
    - Data Volumes: Password protector + Automatic unlock (unlocked when OS boots)
    - All Volumes: Recovery password + recovery key protectors

    Recovery Protector Types Created:
    - Recovery Password: 48-digit numerical password (e.g., 123456-789012-...)
    - Recovery Key: 256-bit .BEK file stored in Active Directory

    Storage Locations:
    - Active Directory: Both passwords AND keys for ALL volumes (domain-joined systems only)
    - RMM Custom Fields: Passwords only for ALL volumes (for quick access)
    - Transcript Log: Full execution details including all passwords for ALL volumes

    The script is safe to run multiple times - it will skip volumes that are already encrypted.

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Administrator privileges
    Requires: TPM 1.2 or 2.0 present and ready
    Requires: Windows 10/11 or Windows Server 2016+
#>

Write-Output "`n=========================================="
Write-Output "BITLOCKER ENABLEMENT WITH TPM"
Write-Output "==========================================`n"

### ————— HELPER FUNCTIONS —————

function Test-DomainJoined {
    <#
    .SYNOPSIS
        Checks if the system is joined to an Active Directory domain.
    #>
    try {
        $result = Test-ComputerSecureChannel -ErrorAction Stop
        return $result
    } catch {
        return $false
    }
}

function Test-TPMPresent {
    <#
    .SYNOPSIS
        Checks if TPM is present and ready for BitLocker.
    #>
    try {
        $tpm = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction Stop

        if ($null -eq $tpm) {
            return @{ Present = $false; Ready = $false; Message = "No TPM found" }
        }

        $isEnabled = $tpm.IsEnabled().IsEnabled
        $isActivated = $tpm.IsActivated().IsActivated
        $isOwned = $tpm.IsOwned().IsOwned

        if ($isEnabled -and $isActivated -and $isOwned) {
            return @{ Present = $true; Ready = $true; Message = "TPM is present and ready" }
        } else {
            $issues = @()
            if (-not $isEnabled) { $issues += "not enabled" }
            if (-not $isActivated) { $issues += "not activated" }
            if (-not $isOwned) { $issues += "not owned" }
            return @{ Present = $true; Ready = $false; Message = "TPM is present but $($issues -join ', ')" }
        }
    } catch {
        return @{ Present = $false; Ready = $false; Message = "Could not query TPM: $_" }
    }
}

function Get-VolumeEncryptionStatus {
    <#
    .SYNOPSIS
        Gets the BitLocker encryption status for a specific volume.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop

        # Check for existing protector types
        $hasTpmProtector = ($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Tpm' }) -ne $null
        $hasPasswordProtector = ($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Password' }) -ne $null

        return @{
            IsProtected = ($volume.ProtectionStatus -eq "On")
            EncryptionPercentage = $volume.EncryptionPercentage
            VolumeStatus = $volume.VolumeStatus
            KeyProtectors = $volume.KeyProtector
            HasTpmProtector = $hasTpmProtector
            HasPasswordProtector = $hasPasswordProtector
        }
    } catch {
        Write-Warning "Could not get BitLocker status for $MountPoint : $_"
        return $null
    }
}

function Enable-BitLockerWithTPM {
    <#
    .SYNOPSIS
        Enables BitLocker on OS volume using TPM as the key protector.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        # Check if TPM protector already exists
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        $hasTpmProtector = ($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Tpm' }) -ne $null

        if ($hasTpmProtector) {
            Write-Output "  ℹ TPM protector already exists, skipping TPM protector creation"
            Write-Output "  → Starting BitLocker encryption (if not already started)..."

            # Try to resume or start protection
            try {
                Resume-BitLocker -MountPoint $MountPoint -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Resume might fail if already enabled, that's okay
            }

            Write-Output "  ✓ BitLocker encryption in progress with existing TPM protector"
            return @{ Success = $true; AlreadyConfigured = $true }
        }

        Write-Output "  → Enabling BitLocker with TPM protector (OS Volume)..."

        # Enable BitLocker with TPM
        Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 -TpmProtector -SkipHardwareTest -ErrorAction Stop

        Write-Output "  ✓ BitLocker enabled successfully with TPM"
        return @{ Success = $true; AlreadyConfigured = $false }
    } catch {
        Write-Warning "  ✗ Failed to enable BitLocker: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Enable-BitLockerWithAutoUnlock {
    <#
    .SYNOPSIS
        Enables BitLocker on a data volume using password protector and enables automatic unlock.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        # Check if password protector already exists
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        $hasPasswordProtector = ($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'Password' }) -ne $null

        if ($hasPasswordProtector) {
            Write-Output "  ℹ Password protector already exists, skipping password protector creation"
            Write-Output "  → Starting BitLocker encryption (if not already started)..."

            # Try to resume protection
            try {
                Resume-BitLocker -MountPoint $MountPoint -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Resume might fail if already enabled, that's okay
            }

            # Try to enable auto-unlock if not already enabled
            Write-Output "  → Enabling automatic unlock..."
            try {
                Enable-BitLockerAutoUnlock -MountPoint $MountPoint -ErrorAction Stop
                Write-Output "  ✓ Automatic unlock enabled"
            } catch {
                Write-Output "  ℹ Automatic unlock already enabled or not applicable"
            }

            Write-Output "  ✓ BitLocker encryption in progress with existing password protector"
            return @{ Success = $true; AlreadyConfigured = $true }
        }

        Write-Output "  → Enabling BitLocker with password protector (Data Volume)..."

        # Enable BitLocker with a password protector (will be hidden by auto-unlock)
        # We use a random password that will be managed by auto-unlock
        $password = ConvertTo-SecureString -String ([System.Guid]::NewGuid().ToString()) -AsPlainText -Force
        Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 -PasswordProtector -Password $password -SkipHardwareTest -ErrorAction Stop

        Write-Output "  ✓ BitLocker enabled successfully"

        # Enable automatic unlock (relies on OS volume being encrypted)
        Write-Output "  → Enabling automatic unlock..."
        Enable-BitLockerAutoUnlock -MountPoint $MountPoint -ErrorAction Stop
        Write-Output "  ✓ Automatic unlock enabled"

        return @{ Success = $true; AlreadyConfigured = $false }
    } catch {
        Write-Warning "  ✗ Failed to enable BitLocker with auto-unlock: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function New-RecoveryPassword {
    <#
    .SYNOPSIS
        Creates a new recovery password (48-digit) for a BitLocker volume.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        Write-Output "  → Creating recovery password..."
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop
        Write-Output "  ✓ Recovery password created successfully"
        return @{ Success = $true }
    } catch {
        Write-Warning "  ✗ Failed to create recovery password: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function New-RecoveryKey {
    <#
    .SYNOPSIS
        Creates a new recovery key (.BEK file) for a BitLocker volume.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        Write-Output "  → Creating recovery key..."
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryKeyProtector -RecoveryKeyPath "$env:TEMP" -ErrorAction Stop
        Write-Output "  ✓ Recovery key created successfully"
        return @{ Success = $true }
    } catch {
        Write-Warning "  ✗ Failed to create recovery key: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Get-RecoveryProtectorStatus {
    <#
    .SYNOPSIS
        Checks if recovery passwords and recovery keys exist for a volume.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        $recoveryPasswords = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
        $recoveryKeys = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'ExternalKey' }

        return @{
            Passwords = @{
                Exists = ($null -ne $recoveryPasswords)
                Count = @($recoveryPasswords).Count
                Values = $recoveryPasswords.RecoveryPassword
                KeyProtectorIds = $recoveryPasswords.KeyProtectorId
            }
            Keys = @{
                Exists = ($null -ne $recoveryKeys)
                Count = @($recoveryKeys).Count
                KeyProtectorIds = $recoveryKeys.KeyProtectorId
            }
        }
    } catch {
        Write-Warning "Could not check recovery protector status for $MountPoint : $_"
        return $null
    }
}

function Backup-RecoveryProtectorsToAD {
    <#
    .SYNOPSIS
        Backs up all recovery passwords and keys for a volume to Active Directory.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    $isDomainJoined = Test-DomainJoined

    if (-not $isDomainJoined) {
        Write-Output "  ℹ System is not domain-joined, skipping AD backup"
        return @{ Skipped = $true; Reason = "Not domain-joined" }
    }

    try {
        $protectorStatus = Get-RecoveryProtectorStatus -MountPoint $MountPoint

        if (-not $protectorStatus.Passwords.Exists -and -not $protectorStatus.Keys.Exists) {
            Write-Warning "  ✗ No recovery protectors found to backup"
            return @{ Success = $false; Reason = "No recovery protectors" }
        }

        $totalProtectors = $protectorStatus.Passwords.Count + $protectorStatus.Keys.Count
        Write-Output "  → Backing up $totalProtectors recovery protector(s) to Active Directory..."

        $successCount = 0

        # Backup recovery passwords
        if ($protectorStatus.Passwords.Exists) {
            foreach ($keyId in $protectorStatus.Passwords.KeyProtectorIds) {
                try {
                    Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $keyId -ErrorAction Stop
                    $successCount++
                } catch {
                    Write-Warning "  ✗ Failed to backup password protector $keyId : $_"
                }
            }
        }

        # Backup recovery keys
        if ($protectorStatus.Keys.Exists) {
            foreach ($keyId in $protectorStatus.Keys.KeyProtectorIds) {
                try {
                    Backup-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $keyId -ErrorAction Stop
                    $successCount++
                } catch {
                    Write-Warning "  ✗ Failed to backup key protector $keyId : $_"
                }
            }
        }

        if ($successCount -gt 0) {
            Write-Output "  ✓ Backed up $successCount recovery protector(s) to AD"
            return @{ Success = $true; Count = $successCount }
        } else {
            Write-Warning "  ✗ Failed to backup any recovery protectors"
            return @{ Success = $false }
        }

    } catch {
        Write-Warning "  ✗ Error during AD backup: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Set-BitLockerADBackupPolicy {
    <#
    .SYNOPSIS
        Configures registry settings to enable automatic BitLocker recovery key backup to Active Directory.
    #>
    param (
        [switch]$Force
    )

    Write-Output "`nConfiguring BitLocker AD backup policy..."

    $registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\FVE"

    # Registry values for AD backup configuration
    $registryValues = @{
        "ActiveDirectoryBackup"              = 1
        "ActiveDirectoryInfoToStore"         = 1
        "RequireActiveDirectoryBackup"       = 1
        "OSActiveDirectoryBackup"            = 1
        "OSActiveDirectoryInfoToStore"       = 1
        "OSRecovery"                         = 1
        "OSRecoveryPassword"                 = 1
        "OSRecoveryKey"                      = 2
        "OSHideRecoveryPage"                 = 1
        "OSManageDRA"                        = 1
        "OSRequireActiveDirectoryBackup"     = 1
        "FDVActiveDirectoryBackup"           = 1
        "FDVActiveDirectoryInfoToStore"      = 1
        "FDVRecovery"                        = 1
        "FDVRecoveryPassword"                = 1
        "FDVRecoveryKey"                     = 2
        "FDVHideRecoveryPage"                = 1
        "FDVManageDRA"                       = 1
        "FDVRequireActiveDirectoryBackup"    = 1
        "RDVActiveDirectoryBackup"           = 1
        "RDVActiveDirectoryInfoToStore"      = 1
        "RDVRecovery"                        = 1
        "RDVRecoveryPassword"                = 1
        "RDVRecoveryKey"                     = 2
        "RDVHideRecoveryPage"                = 1
        "RDVManageDRA"                       = 1
        "RDVRequireActiveDirectoryBackup"    = 1
    }

    # Create registry path if it doesn't exist
    if (-not (Test-Path $registryPath)) {
        try {
            New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
            Write-Output "  → Created registry path: $registryPath"
        } catch {
            Write-Warning "  ✗ Failed to create registry path: $_"
            return $false
        }
    }

    # Set each registry value
    $setCount = 0
    $skipCount = 0

    foreach ($name in $registryValues.Keys) {
        $value = $registryValues[$name]

        try {
            $existingValue = Get-ItemProperty -Path $registryPath -Name $name -ErrorAction SilentlyContinue

            if ($null -eq $existingValue -or $Force) {
                New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType DWORD -Force -ErrorAction Stop | Out-Null
                $setCount++
            } else {
                $skipCount++
            }
        } catch {
            Write-Warning "  ✗ Failed to set $name : $_"
        }
    }

    Write-Output "  ✓ Set $setCount registry value(s), skipped $skipCount existing value(s)"
    return $true
}

### ————— MAIN SCRIPT LOGIC —————

# Check if running with admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Error "This script requires administrator privileges. Please run as administrator."
    Stop-Transcript
    exit 1
}

# Check TPM presence and readiness
Write-Output "Checking TPM availability..."
$tpmStatus = Test-TPMPresent

Write-Output "  TPM Status: $($tpmStatus.Message)"

if (-not $tpmStatus.Present) {
    Write-Error "TPM not found. BitLocker with TPM requires a Trusted Platform Module. Exiting without enabling BitLocker."
    Stop-Transcript
    exit 1
}

if (-not $tpmStatus.Ready) {
    Write-Error "TPM is not ready. Please enable and initialize TPM in BIOS/UEFI settings. Exiting without enabling BitLocker."
    Stop-Transcript
    exit 1
}

Write-Output "  ✓ TPM is ready for BitLocker encryption"

# Check domain join status
$isDomainJoined = Test-DomainJoined

if ($isDomainJoined) {
    Write-Output "`nSystem Status: Domain-joined (AD backup available)"
    Set-BitLockerADBackupPolicy -Force
} else {
    Write-Output "`nSystem Status: Not domain-joined (AD backup unavailable)"
}

Write-Output "`n=========================================="
Write-Output "SCANNING VOLUMES FOR ENCRYPTION"
Write-Output "==========================================`n"

# Get all fixed data volumes
try {
    $allVolumes = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $null -ne $_.DriveLetter }
} catch {
    Write-Error "Failed to enumerate volumes: $_"
    Stop-Transcript
    exit 1
}

if ($allVolumes.Count -eq 0) {
    Write-Output "No fixed volumes found on this system."
    Stop-Transcript
    exit 0
}

# Identify OS volume
$osVolume = $allVolumes | Where-Object { $_.DriveLetter -eq $env:SystemDrive.Trim(':') }
$dataVolumes = $allVolumes | Where-Object { $_.DriveLetter -ne $env:SystemDrive.Trim(':') }

if ($null -eq $osVolume) {
    Write-Error "Could not identify OS volume. Exiting."
    Stop-Transcript
    exit 1
}

Write-Output "Found OS Volume: $($osVolume.DriveLetter):"
if ($dataVolumes.Count -gt 0) {
    Write-Output "Found $($dataVolumes.Count) data volume(s): $(($dataVolumes | ForEach-Object { "$($_.DriveLetter):" }) -join ', ')"
}
Write-Output ""

# Track actions taken
$actionsSummary = @{
    VolumesScanned = 0
    VolumesEncrypted = 0
    VolumesAlreadyEncrypted = 0
    RecoveryProtectorsCreated = 0
    RecoveryProtectorsBackedUp = 0
    Errors = 0
}

# Collect all recovery passwords for RMM storage
$allRecoveryPasswords = @{}

# Variable to track if OS volume is encrypted (needed for auto-unlock)
$osVolumeEncrypted = $false

### ————— PROCESS OS VOLUME FIRST —————

Write-Output "=========================================="
Write-Output "STEP 1: PROCESS OS VOLUME"
Write-Output "==========================================`n"

$mountPoint = "$($osVolume.DriveLetter):"
$actionsSummary.VolumesScanned++

Write-Output "—————————————————————————————————————————"
Write-Output "Volume: $mountPoint ($($osVolume.FileSystemLabel)) [OS VOLUME]"
Write-Output "—————————————————————————————————————————"

# Get encryption status
$encryptionStatus = Get-VolumeEncryptionStatus -MountPoint $mountPoint

if ($null -eq $encryptionStatus) {
    Write-Error "Could not determine encryption status for OS volume. Cannot continue."
    Stop-Transcript
    exit 1
}

# Check if already encrypted or has TPM protector
if ($encryptionStatus.IsProtected) {
    Write-Output "  Status: BitLocker is ALREADY ENABLED"
    Write-Output "  Encryption: $($encryptionStatus.EncryptionPercentage)%"
    Write-Output "  Volume Status: $($encryptionStatus.VolumeStatus)"
    $actionsSummary.VolumesAlreadyEncrypted++
    $osVolumeEncrypted = $true
} elseif ($encryptionStatus.HasTpmProtector) {
    # Has TPM protector but not fully enabled yet (encryption in progress)
    Write-Output "  Status: BitLocker encryption IN PROGRESS"
    Write-Output "  Encryption: $($encryptionStatus.EncryptionPercentage)%"
    Write-Output "  Volume Status: $($encryptionStatus.VolumeStatus)"
    Write-Output "  ℹ TPM protector detected - continuing with existing configuration"
    $actionsSummary.VolumesAlreadyEncrypted++
    $osVolumeEncrypted = $true
} else {
    # Enable BitLocker with TPM on OS volume
    Write-Output "  Status: BitLocker is NOT enabled"
    $enableResult = Enable-BitLockerWithTPM -MountPoint $mountPoint

    if (-not $enableResult.Success) {
        Write-Error "Failed to enable BitLocker on OS volume. Cannot continue with data volumes."
        Stop-Transcript
        exit 1
    }

    $actionsSummary.VolumesEncrypted++
    $osVolumeEncrypted = $true
}

# Create recovery protectors for OS volume
Write-Output "  → Adding recovery protectors..."

$passwordResult = New-RecoveryPassword -MountPoint $mountPoint
if ($passwordResult.Success) {
    $actionsSummary.RecoveryProtectorsCreated++
} else {
    $actionsSummary.Errors++
}

$keyResult = New-RecoveryKey -MountPoint $mountPoint
if ($keyResult.Success) {
    $actionsSummary.RecoveryProtectorsCreated++
} else {
    $actionsSummary.Errors++
}

# Get protector status to collect passwords and backup
$protectorStatus = Get-RecoveryProtectorStatus -MountPoint $mountPoint

# Store recovery passwords for RMM (passwords only, not keys)
if ($protectorStatus.Passwords.Exists) {
    $allRecoveryPasswords[$mountPoint] = $protectorStatus.Passwords.Values
}

# Backup to AD if domain-joined (backup both passwords and keys)
if ($isDomainJoined -and ($protectorStatus.Passwords.Exists -or $protectorStatus.Keys.Exists)) {
    $backupResult = Backup-RecoveryProtectorsToAD -MountPoint $mountPoint

    if ($backupResult.Success) {
        $actionsSummary.RecoveryProtectorsBackedUp += $backupResult.Count
    } elseif (-not $backupResult.Skipped) {
        $actionsSummary.Errors++
    }
}

Write-Output ""

### ————— PROCESS DATA VOLUMES —————

if ($dataVolumes.Count -gt 0) {
    Write-Output "=========================================="
    Write-Output "STEP 2: PROCESS DATA VOLUMES"
    Write-Output "==========================================`n"

    foreach ($vol in $dataVolumes) {
        $mountPoint = "$($vol.DriveLetter):"
        $actionsSummary.VolumesScanned++

        Write-Output "—————————————————————————————————————————"
        Write-Output "Volume: $mountPoint ($($vol.FileSystemLabel)) [DATA VOLUME]"
        Write-Output "—————————————————————————————————————————"

        # Get encryption status
        $encryptionStatus = Get-VolumeEncryptionStatus -MountPoint $mountPoint

        if ($null -eq $encryptionStatus) {
            Write-Warning "  ✗ Could not determine encryption status, skipping"
            $actionsSummary.Errors++
            Write-Output ""
            continue
        }

        # Check if already encrypted or has password protector
        if ($encryptionStatus.IsProtected) {
            Write-Output "  Status: BitLocker is ALREADY ENABLED"
            Write-Output "  Encryption: $($encryptionStatus.EncryptionPercentage)%"
            Write-Output "  Volume Status: $($encryptionStatus.VolumeStatus)"
            $actionsSummary.VolumesAlreadyEncrypted++
        } elseif ($encryptionStatus.HasPasswordProtector) {
            # Has password protector but not fully enabled yet (encryption in progress)
            Write-Output "  Status: BitLocker encryption IN PROGRESS"
            Write-Output "  Encryption: $($encryptionStatus.EncryptionPercentage)%"
            Write-Output "  Volume Status: $($encryptionStatus.VolumeStatus)"
            Write-Output "  ℹ Password protector detected - continuing with existing configuration"
            $actionsSummary.VolumesAlreadyEncrypted++
        } else {
            # Enable BitLocker with auto-unlock on data volume
            Write-Output "  Status: BitLocker is NOT enabled"
            $enableResult = Enable-BitLockerWithAutoUnlock -MountPoint $mountPoint

            if (-not $enableResult.Success) {
                Write-Warning "  ✗ Failed to enable BitLocker, skipping this volume"
                $actionsSummary.Errors++
                Write-Output ""
                continue
            }

            $actionsSummary.VolumesEncrypted++
        }

        # Create recovery protectors for data volume
        Write-Output "  → Adding recovery protectors..."

        $passwordResult = New-RecoveryPassword -MountPoint $mountPoint
        if ($passwordResult.Success) {
            $actionsSummary.RecoveryProtectorsCreated++
        } else {
            $actionsSummary.Errors++
        }

        $keyResult = New-RecoveryKey -MountPoint $mountPoint
        if ($keyResult.Success) {
            $actionsSummary.RecoveryProtectorsCreated++
        } else {
            $actionsSummary.Errors++
        }

        # Get protector status to collect passwords and backup
        $protectorStatus = Get-RecoveryProtectorStatus -MountPoint $mountPoint

        # Store recovery passwords for RMM (passwords only, not keys)
        if ($protectorStatus.Passwords.Exists) {
            $allRecoveryPasswords[$mountPoint] = $protectorStatus.Passwords.Values
        }

        # Backup to AD if domain-joined (backup both passwords and keys)
        if ($isDomainJoined -and ($protectorStatus.Passwords.Exists -or $protectorStatus.Keys.Exists)) {
            $backupResult = Backup-RecoveryProtectorsToAD -MountPoint $mountPoint

            if ($backupResult.Success) {
                $actionsSummary.RecoveryProtectorsBackedUp += $backupResult.Count
            } elseif (-not $backupResult.Skipped) {
                $actionsSummary.Errors++
            }
        }

        Write-Output ""
    }
} else {
    Write-Output "No data volumes found. Skipping Step 2.`n"
}

### ————— SUMMARY REPORT —————

Write-Output "=========================================="
Write-Output "SUMMARY REPORT"
Write-Output "==========================================`n"

Write-Output "Volumes scanned:              $($actionsSummary.VolumesScanned)"
Write-Output "Volumes already encrypted:    $($actionsSummary.VolumesAlreadyEncrypted)"
Write-Output "Volumes newly encrypted:      $($actionsSummary.VolumesEncrypted)"
Write-Output "Recovery protectors created:  $($actionsSummary.RecoveryProtectorsCreated)"

if ($isDomainJoined) {
    Write-Output "Protectors backed up to AD:   $($actionsSummary.RecoveryProtectorsBackedUp)"
}

Write-Output "Errors encountered:           $($actionsSummary.Errors)"

Write-Output "`n=========================================="

if ($actionsSummary.VolumesEncrypted -gt 0) {
    Write-Output "✓ Successfully enabled BitLocker on $($actionsSummary.VolumesEncrypted) volume(s) with TPM"
}

if ($actionsSummary.RecoveryProtectorsCreated -gt 0) {
    Write-Output "✓ Successfully created $($actionsSummary.RecoveryProtectorsCreated) recovery protector(s) (passwords and keys)"
}

if ($actionsSummary.RecoveryProtectorsBackedUp -gt 0) {
    Write-Output "✓ Successfully backed up $($actionsSummary.RecoveryProtectorsBackedUp) protector(s) to Active Directory"
}

if ($actionsSummary.Errors -eq 0) {
    Write-Output "✓ All operations completed successfully"
} else {
    Write-Warning "⚠ Completed with $($actionsSummary.Errors) error(s) - review log for details"
}

Write-Output "=========================================="

### ————— FORMAT RECOVERY PASSWORDS FOR RMM —————

# Format all recovery passwords into a string for RMM storage
$recoveryPasswordsFormatted = ""

if ($allRecoveryPasswords.Count -gt 0) {
    Write-Output "`nFormatting recovery passwords for RMM storage..."

    $passwordLines = @()
    foreach ($mountPoint in ($allRecoveryPasswords.Keys | Sort-Object)) {
        $passwords = $allRecoveryPasswords[$mountPoint]

        if ($passwords -is [array]) {
            # Multiple passwords for this volume
            for ($i = 0; $i -lt $passwords.Count; $i++) {
                if ($passwords.Count -gt 1) {
                    $passwordLines += "$mountPoint (Password $($i + 1)): $($passwords[$i])"
                } else {
                    $passwordLines += "$mountPoint $($passwords[$i])"
                }
            }
        } else {
            # Single password
            $passwordLines += "$mountPoint $passwords"
        }
    }

    $recoveryPasswordsFormatted = $passwordLines -join " | "

    Write-Output "  ✓ Formatted $($allRecoveryPasswords.Count) volume(s) with recovery passwords"
    Write-Output "`nRecovery Passwords (for RMM storage):"
    Write-Output $recoveryPasswordsFormatted
}

### ————— TUNNEL OUTPUT VARIABLE TO YOUR RMM HERE —————
# Available output variables for RMM custom fields:
#
# STATISTICS (numeric values):
# - $actionsSummary.VolumesScanned             : Total volumes checked
# - $actionsSummary.VolumesAlreadyEncrypted    : Volumes that were already encrypted
# - $actionsSummary.VolumesEncrypted           : Volumes newly encrypted
# - $actionsSummary.RecoveryProtectorsCreated  : Number of new recovery protectors created
# - $actionsSummary.RecoveryProtectorsBackedUp : Number of protectors backed up to AD
# - $actionsSummary.Errors                     : Number of errors encountered
#
# RECOVERY PASSWORDS (string - SENSITIVE DATA):
# - $recoveryPasswordsFormatted                : All recovery passwords (48-digit) formatted as:
#                                               "C: 123456-789012... | D: 234567-890123..."
#
# IMPORTANT SECURITY NOTES:
# - Recovery passwords are HIGHLY SENSITIVE credentials that can decrypt drives
# - Store them in secure custom fields with restricted access in your RMM platform
# - Recovery KEYS (.BEK files) are stored in Active Directory only, NOT in RMM
# - RMM stores PASSWORDS only for quick access when unlocking systems
#
# STORAGE SUMMARY:
# - Active Directory: Both passwords AND keys (full backup)
# - RMM Custom Fields: Passwords only (quick access)
# - Transcript Log: Full details including all passwords
#
# Example for NinjaRMM:
# if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
#     Ninja-Property-Set -Name 'bitlockerVolumesEncrypted' -Value $actionsSummary.VolumesEncrypted
#     Ninja-Property-Set -Name 'bitlockerProtectorsCreated' -Value $actionsSummary.RecoveryProtectorsCreated
#     # NOTE: Create 'bitlockerRecoveryPasswords' as a WYSIWYG or secure text custom field in NinjaRMM
#     Ninja-Property-Set -Name 'bitlockerRecoveryPasswords' -Value $recoveryPasswordsFormatted
# }
#
# Example for ConnectWise Automate:
# Set-ItemProperty -Path "HKLM:\SOFTWARE\LabTech\Service" -Name "BitLockerVolumes" -Value $actionsSummary.VolumesEncrypted
# Set-ItemProperty -Path "HKLM:\SOFTWARE\LabTech\Service" -Name "BitLockerPasswords" -Value $recoveryPasswordsFormatted
#
# Example for Datto RMM:
# Write-Host "<-Start Result->"
# Write-Host "ENCRYPTED_VOLUMES: $($actionsSummary.VolumesEncrypted)"
# Write-Host "RECOVERY_PASSWORDS: $recoveryPasswordsFormatted"
# Write-Host "<-End Result->"
#
# NOTE: Encryption will begin in the background. Initial encryption may take several hours
# depending on drive size and system performance. The system remains usable during encryption.
### ————— END RMM OUTPUT TUNNEL —————

Stop-Transcript
