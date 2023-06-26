# Install & Import PowershellGet
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowershellGet

# Install & Import the Exchange Online module
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
Import-Module ExchangeOnlineManagement


# Connect to Exchange Online
Connect-ExchangeOnline -Credential (Get-Credential)

# Specify the path to the CSV file containing mailbox details
$csvPath = Read-Host "Enter CSV Path"

# Read the CSV file
$mailboxList = Import-Csv -Path $csvPath

# Iterate through each row in the CSV and create shared mailboxes
foreach ($mailbox in $mailboxList) {
    $displayName = $mailbox.DisplayName
    $alias = $mailbox.Alias
    $emailAddress = $mailbox.EmailAddress
    $membersFullAccess = $mailbox.MembersFullAccess -split ','
    $membersSendAs = $mailbox.MembersSendAs -split ','
    $membersSendOnBehalf= $mailbox.MembersSendOnBehalf -split ','

    # Create the shared mailbox
    $existingMailbox = Get-Mailbox | Where -Property PrimarySmtpAddress -eq $emailAddress
    if ($existingMailbox.RecipientTypeDetails -ne "SharedMailbox") {
        Write-Host "Converting User mailbox $emailAddress to a shared mailbox."
        Set-Mailbox -Identity $emailAddress -Type Shared
        Write-Host "Converted $emailAddress."
    }

    if ($existingMailbox) {
    # Add members to the shared mailbox
    Write-Host "Mailbox $emailAddress already exists. Setting permissions."
    $memberFullAccess | ForEach-Object {Remove-MailboxPermission -Identity $emailAddress  -User $_ -AccessRights FullAccess}
    $membersFullAccess | ForEach-Object {Add-MailboxPermission -Identity $emailAddress -User $_ -AccessRights FullAccess -InheritanceType All}
    $membersSendAs | ForEach-Object {Remove-RecipientPermission -Identity $emailAddress -AccessRights SendAs -Trustee $_ -Confirm:$false}
    $membersSendAs | ForEach-Object {Add-RecipientPermission -Identity $emailAddress -AccessRights SendAs -Trustee $_ -Confirm:$false}
    $membersSendOnBehalf | ForEach-Object {Set-Mailbox -Identity $emailAddress -GrantSendOnBehalfTo @{remove=$_}}
    $membersSendOnBehalf | ForEach-Object {Set-Mailbox -Identity $emailAddress -GrantSendOnBehalfTo $_}
    Write-Host "Set permissions."
    }  else {
    # Create mailboxes
    Write-Host "$emailAddress doesn't exist as a shared mailbox. Creating one."
    New-Mailbox -Name $displayName -Alias $alias -Shared -PrimarySmtpAddress $emailAddress
    Write-Host "Created $emailAddress as a shared mailbox"

    # Set the display name
    Set-Mailbox -Identity $emailAddress -DisplayName $displayName
    }

}

# Disconnect from Exchange Online
Disconnect-ExchangeOnline
