# Install & Import POwershellGet
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowershellGet

# Install & Import the Exchange Online module
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
Import-Module ExchangeOnlineManagement

# Import the AzureAD module
Install-Module -Name AzureAd -Force -AllowClobber
Import-Module AzureAD

# Connect to Exchange Online
Connect-ExchangeOnline
Connect-AzureAd

# Specify the path to save the CSV file
$csvPath = "C:\HasMailbox.csv"

# Get all user accounts in Exchange Online
$users = Get-AzureAdUser -All:$true

# Create an array to store user details
$usersWithMailboxes = @()

# Iterate through each user and check if they have an Exchange Online mailbox
foreach ($user in $users) {
    $mailbox = Get-Mailbox -Identity $user.UserPrincipalName -ErrorAction SilentlyContinue

    # If the mailbox is not found, add the user details to the array
    if ($mailbox) {
        $userDetails = @{
            DisplayName = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            DirectorySync = $user.DirectorySyncEnabled
            EmailAddress = $mailbox.PrimarySmtpAddress
            EmailAddresses = $mailbox.EmailAddresses
        }
        $usersWithMailboxes += New-Object PSObject -Property $userDetails
    }
}

# Export the users without an Exchange Online mailbox to a CSV file
$usersWithMailboxes | Export-Csv -Path $csvPath -NoTypeInformation

# Display a summary of the exported data
$usersCount = $users.Count
$usersWithMailboxesCount = $usersWithMailboxes.Count
Write-Host "Total users: $usersCount"
Write-Host "Users with Exchange Online mailbox: $usersWithMailboxesCount"

# Disconnect from Exchange Online
Disconnect-ExchangeOnline