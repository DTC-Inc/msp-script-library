# Import PowerShell Get Module
Import-Module PowershellGet

# Install Exchange Online module
Install-Module -Name ExchangeOnlineManagement

# Import the Exchange Online module
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline -Credential (Get-Credential)

# Specify the path to save the CSV file
$csvPath = "C:\SharedMailboxList.csv"

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
    $membersFullAccess = Get-MailboxPermission -Identity $emailAddress | Where-Object { $_.AccessRights -like "FullAccess" } | Select-Object -ExpandProperty User
    $membersSendAs = Get-RecipientPermission -Identity $emailAddress | Where-Object { $_.AccessRights -like "SendAs" } | Get-Mailbox
    $membersSendOnBehalf = Get-Mailbox -Identity $emailAddress | Where -Property GrantSendOnBehalfTo -ne $null | Get-Mailbox
    # Create a hashtable of mailbox details
    $mailboxInfo = @{
        DisplayName = $displayName
        Alias = $alias
        EmailAddress = $emailAddress
        MembersFullAccess = $membersFullAccess -join ","
        MembersSendAs = $membersSendAs.UserPrincipalName -join ","
        MembersSendOnBehalf = $membersSendOnBehalf.UserPrincipalName -join ","
    }

    # Add the mailbox details to the array
    $mailboxDetails += New-Object PSObject -Property $mailboxInfo
}

# Export the mailbox details to a CSV file
$mailboxDetails | Export-Csv -Path $csvPath -NoTypeInformation

# Disconnect from Exchange Online
Disconnect-ExchangeOnline