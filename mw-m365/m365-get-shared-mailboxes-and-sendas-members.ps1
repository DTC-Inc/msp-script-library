# Import PowerShell Get Module
Import-Module PowershellGet

# Install Exchange Online module
Install-Module -Name ExchangeOnlineManagement

# Import the Exchange Online module
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline -Credential (Get-Credential)

# Specify the path to save the CSV file
$csvPath = "C:\SharedMailboxList-SendAs.csv"

# Get all shared mailboxes in the tenant
$sharedMailboxes = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited

# Create an array to store mailbox details
$mailboxDetails = @()

# Iterate through each shared mailbox and retrieve its details
foreach ($mailbox in $sharedMailboxes) {
    $displayName = $mailbox.DisplayName
    $alias = $mailbox.Alias
    $emailAddress = $mailbox.PrimarySmtpAddress
    

    # Get the members of the shared mailbox
    $members = Get-RecipientPermission -Identity $emailAddress | Where-Object { $_.AccessRights -like "SendAs" } | Select-Object -ExpandProperty Identity

    # Create a hashtable of mailbox details
    $mailboxInfo = @{
        DisplayName = $displayName
        Alias = $alias
        EmailAddress = $emailAddress
        Members = $members -join ","
    }

    # Add the mailbox details to the array
    $mailboxDetails += New-Object PSObject -Property $mailboxInfo
}

# Export the mailbox details to a CSV file
$mailboxDetails | Export-Csv -Path $csvPath -NoTypeInformation

# Disconnect from Exchange Online
Disconnect-ExchangeOnline