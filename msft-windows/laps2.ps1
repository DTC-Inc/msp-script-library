## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Local Administrator Password Solution (LAPS) - Enhanced Version
# This script creates/manages a local administrator account with a secure, user-friendly password
# 
# Password Generation Improvements:
# - Excludes problematic symbols that could break scripts: |, ;, <, >, ?, &, {, }, [, ], \, /, ', ", `, ^
# - Excludes easily confused characters: 0 vs O, 1 vs l vs I  
# - Uses only safe, easy-to-type symbols: !@#$%*()_+-=:,.
# - Guarantees at least one uppercase, lowercase, number, and symbol
# - Default 16-character length (configurable)
# - Shuffles password to randomize character positions
#
# RMM Variables (optional):
# $PasswordLength = 16 (Default password length - can be customized)
# $localUser = "admin" (Default local user name - can be customized)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "laps.log"

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

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# Check if the computer is a domain controller or Azure AD joined
# PowerShell Script to Check if the Server is a Domain Controller
$serverRole = Get-WmiObject -Class Win32_ComputerSystem

if ($serverRole.DomainRole -eq 4 -or $serverRole.DomainRole -eq 5) {
    Write-Host "This server IS a Domain Controller. Exiting"
    Exit 0
} else {
    Write-Host "This server is NOT a Domain Controller."
    Write-Host "Continuing to run LAPS."
}

# Function to check if azure ad joined
function Test-AzureAdJoined {
        $AzureADKey = Test-Path "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo"
        if ($AzureADKey) {
            $subKey = Get-Item "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo/*"
    
            try {
                foreach($key in $subKey) {
                    $tenantId = $key.GetValue("TenantId");
                    $userEmail = $key.GetValue("UserEmail");
                }

                Write-Host "Tenant ID: $($tenantId)" 
                Write-Host "User Email: $($userEmail)"
                if ($tenantId) { 
                    return $True
                } else {
                    return $False
                }
            } catch {
                return $False
            }
        } else {
                return $False
        }
}

# Function to generate a user-friendly random password
function Generate-RandomPassword {
    param(
        [int]$Length = 16  # Default 16 characters (configurable)
    )
    
    # User-friendly character sets (excluding problematic symbols)
    # Removed: |, ;, <, >, ?, &, {, }, [, ], \, /, ', ", `, ^
    # Removed confusing characters: 0 (zero), O (oh), 1 (one), l (lowercase L), I (uppercase i)
    $lowercase = 'abcdefghijkmnpqrstuvwxyz'      # Removed: l, o
    $uppercase = 'ABCDEFGHJKLMNPQRSTUVWXYZ'      # Removed: I, O
    $numbers = '23456789'                        # Removed: 0, 1
    $symbols = '!@#$%*()_+-=:,.'                # Safe, easy-to-type symbols only
    
    # Ensure password contains at least one character from each set
    $password = ""
    $password += $lowercase[(Get-Random -Minimum 0 -Maximum $lowercase.Length)]
    $password += $uppercase[(Get-Random -Minimum 0 -Maximum $uppercase.Length)]
    $password += $numbers[(Get-Random -Minimum 0 -Maximum $numbers.Length)]
    $password += $symbols[(Get-Random -Minimum 0 -Maximum $symbols.Length)]
    
    # Fill remaining length with random characters from all sets
    $allCharacters = $lowercase + $uppercase + $numbers + $symbols
    for ($i = 4; $i -lt $Length; $i++) {
        $password += $allCharacters[(Get-Random -Minimum 0 -Maximum $allCharacters.Length)]
    }
    
    # Shuffle the password to randomize the guaranteed character positions
    $passwordArray = $password.ToCharArray()
    for ($i = $passwordArray.Length - 1; $i -gt 0; $i--) {
        $j = Get-Random -Minimum 0 -Maximum ($i + 1)
        $temp = $passwordArray[$i]
        $passwordArray[$i] = $passwordArray[$j]
        $passwordArray[$j] = $temp
    }
    
    return ($passwordArray -join '')
}

# Function to check if a user exists
function User-Exists {
    param(
        [string]$username
    )
    $user = Get-LocalUser -Name $username
    return [bool]($user -ne $null)
}

# Function to add a user to the local Administrators group
function Add-UserToLocalAdministrators {
    param(
        [string]$username
    )
    $group = [ADSI]"WinNT://./Administrators,group"
    $group.Add("WinNT://$env:COMPUTERNAME/$username")
}

# Set default values if not provided by RMM
if ($null -eq $PasswordLength) {
    $PasswordLength = 16  # Default password length
}

if ($null -eq $localUser) {
    $localUser = "admin"  # Default local user name
}

Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  - Local User: $localUser" -ForegroundColor White
Write-Host "  - Password Length: $PasswordLength characters" -ForegroundColor White
Write-Host "  - Character Sets: Letters (no confusing chars), Numbers (2-9), Safe symbols (!@#$%*()_+-=:,.)" -ForegroundColor White
Write-Host ""

# Generate a user-friendly random password
Write-Host "Generating secure, user-friendly password..." -ForegroundColor Yellow
$password = Generate-RandomPassword -Length $PasswordLength

# Display password composition for verification
$hasLower = $password -cmatch '[a-z]'
$hasUpper = $password -cmatch '[A-Z]'
$hasNumber = $password -cmatch '[2-9]'
$hasSymbol = $password -cmatch '[!@#$%*()_+\-=:,.]'

Write-Host "✓ Password generated successfully" -ForegroundColor Green
Write-Host "  - Contains lowercase letters: $(if($hasLower){'✓'}else{'❌'})" -ForegroundColor Gray
Write-Host "  - Contains uppercase letters: $(if($hasUpper){'✓'}else{'❌'})" -ForegroundColor Gray
Write-Host "  - Contains numbers (2-9): $(if($hasNumber){'✓'}else{'❌'})" -ForegroundColor Gray
Write-Host "  - Contains safe symbols: $(if($hasSymbol){'✓'}else{'❌'})" -ForegroundColor Gray

# Check if the user exists
Write-Host "Checking if local user '$localUser' exists..." -ForegroundColor Yellow
if (!(User-Exists -username $localUser)) {
    # Create the local user if it doesn't exist
    Write-Host "User '$localUser' does not exist. Creating new local user..." -ForegroundColor Yellow
    $SecurePassword = ConvertTo-SecureString -String "$password" -AsPlainText -Force
    try {
        $newUser = New-LocalUser -Name $localUser -Password $SecurePassword -PasswordNeverExpires:$True -UserMayNotChangePassword:$True -AccountNeverExpires:$True
        if ($null -eq $newUser) {
            Write-Host "❌ Failed to create user '$localUser'." -ForegroundColor Red
            Exit 1
        }
        Write-Host "✓ Local user '$localUser' created successfully" -ForegroundColor Green
        Write-Host "Adding user to local Administrators group..." -ForegroundColor Yellow
        # Add the user to the local Administrators group
        Add-UserToLocalAdministrators -username $localUser
        Write-Host "✓ User '$localUser' added to Administrators group" -ForegroundColor Green
    } catch {
        Write-Host "❌ Failed to create user '$localUser': $($_.Exception.Message)" -ForegroundColor Red
        Exit 1
    }
} else {
    Write-Host "✓ User '$localUser' already exists" -ForegroundColor Green
    Write-Host "Ensuring user is in local Administrators group..." -ForegroundColor Yellow
    # Add the existing user to the local Administrators group
    try {
        Add-UserToLocalAdministrators -username $localUser
        Write-Host "✓ User '$localUser' is in Administrators group" -ForegroundColor Green
    } catch {
        Write-Host "⚠ User may already be in Administrators group" -ForegroundColor Yellow
    }
}

# Set password for specified local user
Write-Host "Setting password for user '$localUser'..." -ForegroundColor Yellow
net user $localUser $password > $null  # Redirect output to suppress password display
Write-Host "✓ Password set for user '$localUser'" -ForegroundColor Green
# Check if the computer is domain-joined

# Testing if endpoint is joined to a legacy Windows Active Directory domain.
Write-Host "Checking domain join status..." -ForegroundColor Yellow
if (Test-ComputerSecureChannel) {
    Write-Host "✓ Endpoint is joined to Active Directory domain" -ForegroundColor Green
    Write-Host "Setting password for Built-in Administrator and disabling account..." -ForegroundColor Yellow
    $adminUsername = "Administrator"
    net user $adminUsername $password > $null  # Redirect output to suppress password display
    Write-Host "✓ Password set for built-in Administrator" -ForegroundColor Green
    net user administrator /active:no > $null
    Write-Host "✓ Built-in Administrator account disabled" -ForegroundColor Green
} else {
    Write-Host "Endpoint is not domain joined" -ForegroundColor Gray
}

# Testing if endpoint is Azure AD joined.
Write-Host "Checking Microsoft Entra ID (Azure AD) join status..." -ForegroundColor Yellow
if (Test-AzureADJoined) {
    Write-Host "✓ Endpoint is joined to Microsoft Entra ID" -ForegroundColor Green
    Write-Host "Setting password for Built-in Administrator and disabling account..." -ForegroundColor Yellow
    $adminUsername = "Administrator"
    net user $adminUsername $password > $null  # Redirect output to suppress password display
    Write-Host "✓ Password set for built-in Administrator" -ForegroundColor Green
    net user administrator /active:no > $null
    Write-Host "✓ Built-in Administrator account disabled" -ForegroundColor Green
} else {
    Write-Host "Endpoint is not Azure AD joined" -ForegroundColor Gray
}


Write-Host ""
Write-Host "=== LAPS Configuration Summary ===" -ForegroundColor Cyan
Write-Host "Local Administrator Account: $localUser" -ForegroundColor White
Write-Host "Password Length: $PasswordLength characters" -ForegroundColor White
Write-Host "Password Complexity: Mixed case, numbers (2-9), safe symbols" -ForegroundColor White
Write-Host "Characters Excluded: Confusing (0,O,1,l,I) and problematic symbols" -ForegroundColor White
Write-Host "Account Settings: Password never expires, user cannot change password" -ForegroundColor White
Write-Host "===============================" -ForegroundColor Cyan
Write-Host ""

# Log the generated password for administrative reference
Write-Host "Generated Password for '$localUser': $password" -ForegroundColor Yellow
Write-Host "⚠ Store this password securely for recovery purposes" -ForegroundColor Yellow
Write-Host ""

Write-Host "✅ LAPS configuration completed successfully!" -ForegroundColor Green
Write-Host "Local administrator account '$localUser' is ready for use." -ForegroundColor Green

Stop-Transcript
