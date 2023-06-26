# Install & Import PowershellGet
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowershellGet

# Install & Import the Exchange Online module
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline -Credential (Get-Credential)

# Specify the path to save the CSV file
$csvPath = "C:\UnifiedGroups3.csv"

# Get all shared mailboxes in the tenant
$unifiedGroups = Get-UnifiedGroup  -ResultSize Unlimited

# Create an array to store mailbox details
$groupDetails = @()

# Iterate through each shared mailbox and retrieve its details
foreach ($group in $unifiedGroups) {
    $displayName = $group.DisplayName
    $alias = $group.Alias
    $emailAddress = $group.PrimarySmtpAddress
    $aliasEmailAddresses = $group.EmailAddresses
    $groupType = $group.ResourceProvisioningOptions
    $AccessType = $group.AccessType
    $owners = $group| Get-UnifiedGroupLinks -LinkType Owners | Select -ExpandProperty PrimarySmtpAddress
    $members = $group | Get-UnifiedGroupLinks -LinkType Members | Select -ExpandProperty PrimarySmtpAddress
    $membersSendAs = Get-RecipientPermission -Identity $emailAddress | Where-Object { $_.AccessRights -like "SendAs" } | Get-Mailbox
    
    # Create a hashtable of mailbox details
    $groupInfo = @{
        DisplayName = $displayName
        Alias = $alias
        EmailAddress = $emailAddress
        AliasEmailAddresses = $aliasEmailAddresses -join ","
        GroupType = $groupType
        AccessType = $accessType
        Owners = $owners -join ","
        MembersSendAs = $membersSendAs.UserPrincipalName -join ","
        Members = $members -join ","
    }

    # Add the mailbox details to the array
    $groupDetails += New-Object PSObject -Property $groupInfo
}

# Export the mailbox details to a CSV file
$groupDetails | Export-Csv -Path $csvPath -NoTypeInformation

# Disconnect from Exchange Online
Disconnect-ExchangeOnline