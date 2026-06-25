## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $csvPath / $env:csvPath - REQUIRED. Path to the CSV file containing mailbox details

param(
    # Defaults to its $env: counterpart so the script runs the same from the command line
    # (-csvPath ...) or from an RMM that supplies the value as an env variable. There is no
    # Read-Host: the script is non-interactive by design and never blocks on input.
    [string]$csvPath = $env:csvPath
)

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Required input. Must come from -Parameter or $env: -- there is no prompt fallback.
if ([string]::IsNullOrEmpty($csvPath)) {
    Write-Error "ERROR: Required input not provided (set as -Parameter or `$env:): csvPath"
    exit 1
}

# Install & Import PowershellGet
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowershellGet

# Install & Import the Exchange Online module
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
Import-Module ExchangeOnlineManagement


# Connect to Exchange Online
Connect-ExchangeOnline -Credential (Get-Credential)

# Specify the path to the CSV file containing mailbox details
# ($csvPath is supplied via the -csvPath parameter or $env:csvPath -- see top of script.)

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
