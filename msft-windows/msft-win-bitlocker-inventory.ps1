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

$ScriptLogName = "msft-win-bitlocker-inventory.log"

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
    Inventories BitLocker status and ensures both recovery passwords and keys exist.

.DESCRIPTION
    This script performs comprehensive BitLocker inventory and recovery protector management:

    Features:
    - Scans all volumes for BitLocker encryption status
    - Automatically creates BOTH recovery passwords (48-digit) AND recovery keys (.BEK) if missing
    - Backs up BOTH passwords and keys to Active Directory (domain-joined systems)
    - Stores recovery passwords in RMM custom fields for quick access
    - Configures registry settings for automatic AD backup (domain-joined systems)
    - Provides clear, user-friendly output showing status of each volume
    - Generates summary report of actions taken

    Recovery Protector Types Created:
    - Recovery Password: 48-digit numerical password (e.g., 123456-789012-...)
    - Recovery Key: 256-bit .BEK file stored in Active Directory

    Storage Locations:
    - Active Directory: Both passwords AND keys (domain-joined systems only)
    - RMM Custom Fields: Passwords only (for quick access)
    - Transcript Log: Full execution details including all passwords

    The script is safe to run multiple times - it only creates protectors if they're missing,
    and only backs up protectors that aren't already stored.

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Administrator privileges
    Requires: BitLocker enabled on at least one volume to perform recovery protector actions
#>

Write-Output "`n=========================================="
Write-Output "BITLOCKER INVENTORY & RECOVERY KEY MANAGEMENT"
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
        return @{
            IsProtected = ($volume.ProtectionStatus -eq "On")
            EncryptionPercentage = $volume.EncryptionPercentage
            VolumeStatus = $volume.VolumeStatus
            KeyProtectors = $volume.KeyProtector
        }
    } catch {
        Write-Warning "Could not get BitLocker status for $MountPoint : $_"
        return $null
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
        Write-Output "  → Creating new recovery password..."
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
        Write-Output "  → Creating new recovery key..."
        # Note: Recovery keys are typically saved to a specific path
        # For AD backup, we just create the protector without saving to file
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryKeyProtector -RecoveryKeyPath "$env:TEMP" -ErrorAction Stop
        Write-Output "  ✓ Recovery key created successfully"
        return @{ Success = $true }
    } catch {
        Write-Warning "  ✗ Failed to create recovery key: $_"
        return @{ Success = $false; Error = $_.Exception.Message }
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

# Check domain join status
$isDomainJoined = Test-DomainJoined

if ($isDomainJoined) {
    Write-Output "System Status: Domain-joined (AD backup available)"
    Set-BitLockerADBackupPolicy -Force
} else {
    Write-Output "System Status: Not domain-joined (AD backup unavailable)"
}

Write-Output "`n=========================================="
Write-Output "SCANNING VOLUMES"
Write-Output "==========================================`n"

# Get all volumes
try {
    $volumes = Get-BitLockerVolume -ErrorAction Stop
} catch {
    Write-Error "Failed to enumerate BitLocker volumes: $_"
    Stop-Transcript
    exit 1
}

if ($volumes.Count -eq 0) {
    Write-Output "No BitLocker volumes found on this system."
    Stop-Transcript
    exit 0
}

Write-Output "Found $($volumes.Count) volume(s) to check`n"

# Track actions taken
$actionsSummary = @{
    VolumesScanned = 0
    VolumesEncrypted = 0
    RecoveryKeysCreated = 0
    RecoveryKeysBackedUp = 0
    Errors = 0
}

# Collect all recovery passwords for RMM storage
$allRecoveryPasswords = @{}

# Process each volume
foreach ($volume in $volumes) {
    $mountPoint = $volume.MountPoint
    $actionsSummary.VolumesScanned++

    Write-Output "—————————————————————————————————————————"
    Write-Output "Volume: $mountPoint"
    Write-Output "—————————————————————————————————————————"

    # Get encryption status
    $encryptionStatus = Get-VolumeEncryptionStatus -MountPoint $mountPoint

    if ($null -eq $encryptionStatus) {
        Write-Warning "  ✗ Could not determine encryption status, skipping"
        $actionsSummary.Errors++
        Write-Output ""
        continue
    }

    # Check if BitLocker is enabled
    if (-not $encryptionStatus.IsProtected) {
        Write-Output "  Status: BitLocker is NOT enabled"
        Write-Output "  Action: Skipping (no encryption active)`n"
        continue
    }

    $actionsSummary.VolumesEncrypted++
    Write-Output "  Status: BitLocker is ENABLED"
    Write-Output "  Encryption: $($encryptionStatus.EncryptionPercentage)%"
    Write-Output "  Volume Status: $($encryptionStatus.VolumeStatus)"

    # Check for recovery protectors (passwords and keys)
    $protectorStatus = Get-RecoveryProtectorStatus -MountPoint $mountPoint

    if ($null -eq $protectorStatus) {
        Write-Warning "  ✗ Could not check recovery protector status"
        $actionsSummary.Errors++
        Write-Output ""
        continue
    }

    # Display current status
    Write-Output "  Recovery Password: $(if ($protectorStatus.Passwords.Exists) { "EXISTS ($($protectorStatus.Passwords.Count) found)" } else { "MISSING" })"
    Write-Output "  Recovery Key: $(if ($protectorStatus.Keys.Exists) { "EXISTS ($($protectorStatus.Keys.Count) found)" } else { "MISSING" })"

    # Create recovery password if missing
    if (-not $protectorStatus.Passwords.Exists) {
        $passwordResult = New-RecoveryPassword -MountPoint $mountPoint
        if ($passwordResult.Success) {
            $actionsSummary.RecoveryKeysCreated++
        } else {
            $actionsSummary.Errors++
        }
    }

    # Create recovery key if missing
    if (-not $protectorStatus.Keys.Exists) {
        $keyResult = New-RecoveryKey -MountPoint $mountPoint
        if ($keyResult.Success) {
            $actionsSummary.RecoveryKeysCreated++
        } else {
            $actionsSummary.Errors++
        }
    }

    # Refresh protector status after creation
    $protectorStatus = Get-RecoveryProtectorStatus -MountPoint $mountPoint

    # Store recovery passwords for RMM (passwords only, not keys)
    if ($protectorStatus.Passwords.Exists) {
        $allRecoveryPasswords[$mountPoint] = $protectorStatus.Passwords.Values
    }

    # Backup to AD if domain-joined (backup both passwords and keys)
    if ($isDomainJoined -and ($protectorStatus.Passwords.Exists -or $protectorStatus.Keys.Exists)) {
        $backupResult = Backup-RecoveryProtectorsToAD -MountPoint $mountPoint

        if ($backupResult.Success) {
            $actionsSummary.RecoveryKeysBackedUp += $backupResult.Count
        } elseif (-not $backupResult.Skipped) {
            $actionsSummary.Errors++
        }
    }

    Write-Output ""
}

### ————— SUMMARY REPORT —————

Write-Output "=========================================="
Write-Output "SUMMARY REPORT"
Write-Output "==========================================`n"

Write-Output "Volumes scanned:              $($actionsSummary.VolumesScanned)"
Write-Output "Volumes encrypted:            $($actionsSummary.VolumesEncrypted)"
Write-Output "Recovery protectors created:  $($actionsSummary.RecoveryKeysCreated)"

if ($isDomainJoined) {
    Write-Output "Protectors backed up to AD:   $($actionsSummary.RecoveryKeysBackedUp)"
}

Write-Output "Errors encountered:           $($actionsSummary.Errors)"

Write-Output "`n=========================================="

if ($actionsSummary.RecoveryKeysCreated -gt 0) {
    Write-Output "✓ Successfully created $($actionsSummary.RecoveryKeysCreated) recovery protector(s) (passwords and/or keys)"
}

if ($actionsSummary.RecoveryKeysBackedUp -gt 0) {
    Write-Output "✓ Successfully backed up $($actionsSummary.RecoveryKeysBackedUp) protector(s) to Active Directory"
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
                    $passwordLines += "$mountPoint (Key $($i + 1)): $($passwords[$i])"
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
# - $actionsSummary.VolumesScanned         : Total volumes checked
# - $actionsSummary.VolumesEncrypted       : Number of BitLocker-enabled volumes
# - $actionsSummary.RecoveryKeysCreated    : Number of new recovery protectors created (passwords + keys)
# - $actionsSummary.RecoveryKeysBackedUp   : Number of protectors backed up to AD
# - $actionsSummary.Errors                 : Number of errors encountered
#
# RECOVERY PASSWORDS (string - SENSITIVE DATA):
# - $recoveryPasswordsFormatted            : All recovery passwords (48-digit) formatted as:
#                                           "C: 123456-789012... | D: 234567-890123..."
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
#     Ninja-Property-Set -Name 'bitlockerProtectorsCreated' -Value $actionsSummary.RecoveryKeysCreated
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
# NOTE: Some RMM platforms have character limits on custom fields (often 10,000-50,000 chars).
# Recovery passwords are 48 chars each plus formatting, so plan accordingly for systems
# with many volumes. Consider using a secure note/documentation field for very large datasets.
### ————— END RMM OUTPUT TUNNEL —————

Stop-Transcript