## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $RMMRecoveryPasswordField = "bitlockerRecoveryPassword"  # RMM custom field name for all recovery passwords
## $RMMBitlockerStatusField = "bitlockerStatus"             # RMM custom field name for BitLocker status

# This script inventories BitLocker status across all volumes:
# - Checks BitLocker encryption status on all drives
# - Generates recovery passwords if missing
# - Backs up recovery keys to Active Directory (if domain-joined)
# - Writes recovery passwords and status to RMM custom fields

$ScriptLogName = "msft-win-bitlocker-inventory.log"

# Default values
if ($null -eq $RMMRecoveryPasswordField) { $RMMRecoveryPasswordField = "bitlockerRecoveryPassword" }
if ($null -eq $RMMBitlockerStatusField) { $RMMBitlockerStatusField = "bitlockerStatus" }

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
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        $Description = "RMM-initiated BitLocker inventory"
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# Function to check if the system is joined to a domain
function Get-DomainJoinStatus {
    if (Test-ComputerSecureChannel) {
        return $true
    } else {
        return $false
    }    
}

# Function to check if BitLocker is enabled on a volume
function Get-BitLockerStatus {
    param(
        [string]$DriveLetter
    )
    $status = Get-BitLockerVolume -MountPoint $DriveLetter
    return $status.ProtectionStatus -eq "On"
}

# Function to get or generate a BitLocker recovery password for a volume
function Get-OrGenerateRecoveryPassword {
    param(
        [string]$DriveLetter
    )

    $recoveryPasswords = Get-BitLockerVolume -MountPoint $DriveLetter | Select-Object -ExpandProperty KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }

    if ($recoveryPasswords) {
        return $recoveryPasswords.RecoveryPassword
    } else {
        # If no recovery password is found, generate a new one
        Add-BitLockerKeyProtector -MountPoint $DriveLetter -RecoveryPasswordProtector
        $recoveryPasswords = Get-BitLockerVolume -MountPoint $DriveLetter | Select-Object -ExpandProperty KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
        return $recoveryPasswords.RecoveryPassword
    }
}

# Function to backup the recovery password to AD or AAD
function BackupRecoveryPassword {
    param(
        [string]$DriveLetter
    )

    $domainJoined = Get-DomainJoinStatus

    if ($domainJoined) {
        # Store bitlocker keys in Active Directory computer object
        $KeyProtectorsToBackup = Get-BitlockerVolume -MountPoint $DriveLetter | Select -Expand KeyProtector | Where { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select -Expand KeyProtectorId        
        $KeyProtectorsToBackup | ForEach-Object { Backup-BitLockerKeyProtector -MountPoint $DriveLetter -KeyProtectorId $_ }

   # The below is commented out as the key protector needs to Azure AD aware for a computer/user object or a group. This functionality is limited at the moment.
   # } else {
   #     Add-BitLockerKeyProtector -MountPoint $DriveLetter -AdAccountOrGroupProtector
    }
}

# Function to configure windows for Active Directory Backup
function Set-BitLockerADBackupSettings {
    param (
        [switch]$Force
    )

    # Define the registry path for BitLocker settings
    $registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\FVE"

    # Define the registry values and their corresponding settings
    $registryValues = @{
        "ActiveDirectoryBackup"              = 1
        "ActiveDirectoryInfoToStore"         = 1
        "FDVActiveDirectoryBackup"           = 1
        "FDVActiveDirectoryInfoToStore"      = 1
        "FDVHideRecoveryPage"                = 1
        "FDVManageDRA"                       = 1
        "FDVRecovery"                        = 1
        "FDVRecoveryKey"                     = 2
        "FDVRecoveryPassword"                = 1
        "FDVRequireActiveDirectoryBackup"    = 1
        "OSActiveDirectoryBackup"            = 1
        "OSActiveDirectoryInfoToStore"       = 1
        "OSHideRecoveryPage"                 = 1
        "OSManageDRA"                        = 1
        "OSRecovery"                         = 1
        "OSRecoveryKey"                      = 2
        "OSRecoveryPassword"                 = 1
        "OSRequireActiveDirectoryBackup"     = 1
        "RequireActiveDirectoryBackup"       = 1
        "RDVActiveDirectoryBackup"           = 1
        "RDVActiveDirectoryInfoToStore"      = 1
        "RDVHideRecoveryPage"                = 1
        "RDVManageDRA"                       = 1
        "RDVRecovery"                        = 1
        "RDVRecoveryKey"                     = 2
        "RDVRecoveryPassword"                = 1
        "RDVRequireActiveDirectoryBackup"    = 1
    }

    # Create the registry path if it doesn't exist
    if (-not (Test-Path $registryPath)) {
        New-Item -Path $registryPath -Force
    }

    # Iterate through each registry value and set it
    foreach ($name in $registryValues.Keys) {
        $value = $registryValues[$name]
        
        if (-not (Get-ItemProperty -Path $registryPath -Name $name -ErrorAction SilentlyContinue) -or $Force) {
            Write-Output "Setting $name to $value in $registryPath"
            New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
        } else {
            Write-Output "Registry key $name already exists with the desired value."
        }
    }

    Write-Output "BitLocker AD Backup settings have been configured."
}


# Main script
$volumes = Get-BitLockerVolume
$recoveryPasswords = @{}

# Configure Bitlocker Active Directory backup if endpoint is joined to an Active Directory domain.
if (Get-DomainJoinStatus) {
    Set-BitLockerADBackupSettings -Force

}

# Generate Bitlocker recovery passwords and, or store in Active Directory / Entra ID.
foreach ($volume in $volumes) {
    $driveLetter = $volume.MountPoint

    if (Get-BitLockerStatus -DriveLetter $driveLetter) {
        $password = Get-OrGenerateRecoveryPassword -DriveLetter $driveLetter
        $recoveryPasswords[$driveLetter] = $password
        BackupRecoveryPassword -DriveLetter $driveLetter
    } else {
        Write-Output "BitLocker is not enabled on $driveLetter"
    }
}

# Output recovery passwords and status to RMM custom fields
if ($RMM -eq 1) {
    Write-Host ""
    Write-Host "=== RMM Output ===" -ForegroundColor Cyan

    # Build recovery password field (all drives in one field)
    $recoveryEntries = @()
    foreach ($drive in $recoveryPasswords.Keys) {
        $pw = $recoveryPasswords[$drive]
        if ($pw) {
            $recoveryEntries += "$drive $pw"
        }
    }
    $recoveryFieldValue = $recoveryEntries -join " | "

    # Build status field (all drives in one field)
    $statusEntries = @()
    foreach ($volume in $volumes) {
        $encStatus = if ($volume.ProtectionStatus -eq "On") { "Encrypted" } else { "Not Encrypted" }
        $statusEntries += "$($volume.MountPoint) $encStatus"
    }
    $statusFieldValue = $statusEntries -join " | "

    Write-Host "Recovery field: $recoveryFieldValue"
    Write-Host "Status field: $statusFieldValue"

    $ninjaCmd = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($ninjaCmd) {
        if ($recoveryFieldValue) {
            Ninja-Property-Set $RMMRecoveryPasswordField "$recoveryFieldValue"
            Write-Host "NinjaRMM: Set $RMMRecoveryPasswordField" -ForegroundColor Green
        }
        Ninja-Property-Set $RMMBitlockerStatusField "$statusFieldValue"
        Write-Host "NinjaRMM: Set $RMMBitlockerStatusField" -ForegroundColor Green
    } else {
        Write-Host "BITLOCKER_RECOVERY_PASSWORDS=$recoveryFieldValue"
        Write-Host "BITLOCKER_STATUS=$statusFieldValue"
    }
}

Stop-Transcript
