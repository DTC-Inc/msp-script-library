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
$csvPath = "C:\NoMailbox.csv"

# Get all user accounts in Exchange Online
$users = Get-AzureAdUser -ResultSize Unlimited

# Create an array to store user details
$usersWithoutMailbox = @()

# Iterate through each user and check if they have an Exchange Online mailbox
foreach ($user in $users) {
    $mailbox = Get-Mailbox -Identity $user.UserPrincipalName -ErrorAction SilentlyContinue

    # If the mailbox is not found, add the user details to the array
    if (!$mailbox) {
        $userDetails = @{
            DisplayName = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
        }
        $usersWithoutMailbox += New-Object PSObject -Property $userDetails
    }
}

# Export the users without an Exchange Online mailbox to a CSV file
$usersWithoutMailbox | Export-Csv -Path $csvPath -NoTypeInformation

# Display a summary of the exported data
$usersCount = $users.Count
$usersWithoutMailboxCount = $usersWithoutMailbox.Count
Write-Host "Total users: $usersCount"
Write-Host "Users without Exchange Online mailbox: $usersWithoutMailboxCount"

# Disconnect from Exchange Online
Disconnect-ExchangeOnline