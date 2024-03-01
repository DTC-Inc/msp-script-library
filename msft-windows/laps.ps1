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
$os = Get-WmiObject -Class Win32_OperatingSystem
$isDomainController = $os.Roles -contains "Domain Controller"

# Checking if Azure AD Joined
$subKey = Get-Item "HKLM:/SYSTEM/CurrentControlSet/Control/CloudDomainJoin/JoinInfo"

$guids = $subKey.GetSubKeyNames()
foreach($guid in $guids) {

    $guidSubKey = $subKey.OpenSubKey($guid);
    $tenantId = $guidSubKey.GetValue("TenantId");
    $userEmail = $guidSubKey.GetValue("UserEmail");
}


# Function to generate a random password
function Generate-RandomPassword {
    $symbols = '!@#$%^&*()_+-=[]{}|;:,.<>?'
    $characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' + $symbols
    $password = ""
    for ($i = 0; $i -lt 32; $i++) {
        $password += $characters[(Get-Random -Minimum 0 -Maximum $characters.Length)]
    }
    return $password
}

# Function to check if a user exists
function User-Exists {
    param(
        [string]$username
    )
    $user = Get-WmiObject Win32_UserAccount | Where-Object { $_.Name -eq $username }
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

# Generate a random password
$password = Generate-RandomPassword

# Specify the local user
# $localUser = "username"  # Replace "username" with the desired local user

# Check if the user exists
if (-not (User-Exists -username $localUser)) {
    # Create the local user if it doesn't exist
    $newUser = New-LocalUser -Name $localUser -Password $password -PasswordNeverExpires $true -UserMayNotChangePassword $true -AccountNeverExpires $true
    if ($newUser -eq $null) {
        Write-Output "Failed to create user $localUser."
        Exit 1
    }
    # Add the user to the local Administrators group
    Add-UserToLocalAdministrators -username $localUser
} else {
    # Add the existing user to the local Administrators group
    Add-UserToLocalAdministrators -username $localUser
}

# Set password for specified local user
net user $localUser $password > $null  # Redirect output to suppress password display

# Check if the computer is domain-joined
if (-not (Test-ComputerSecureChannel)) {
    # Set password for built-in administrator
    $adminUsername = "Administrator"
    net user $adminUsername $password > $null  # Redirect output to suppress password display
    Write-Output "Password set for built-in administrator."
}

if ($tenantId) { 
        # Set password for built-in administrator
        $adminUsername = "Administrator"
        net user $adminUsername $password > $null  # Redirect output to suppress password display
        Write-Output "Password set for built-in administrator."

}


# Display a message about password setting completion
Write-Output "Password set for user $localUser."

# You can uncomment the next line if you want to log the generated password for your reference
# Write-Output "Generated Password: $password"


Stop-Transcript
