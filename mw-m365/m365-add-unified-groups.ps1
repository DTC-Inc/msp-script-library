## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $csvPath    / $env:csvPath    - REQUIRED. Path to the CSV file containing the group details
## $domainName / $env:domainName - New domain name for created groups (default: "league91.com")

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-csvPath ...) or from an RMM that supplies values as env variables.
    [string]$csvPath    = $env:csvPath,
    [string]$domainName = $env:domainName
)

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Validate required input. This must come from -Parameter or $env: -- there is no prompt.
if ([string]::IsNullOrEmpty($csvPath)) {
    Write-Error "ERROR: Required input csvPath not provided (set as -Parameter or `$env:csvPath)."
    exit 1
}

# Default the new domain name if it was not supplied.
if ([string]::IsNullOrEmpty($domainName)) {
    $domainName = "league91.com"
}

# Install & Import POwershellGet
Install-Module -Name PowerShellGet -Force -AllowClobber
Import-Module PowershellGet

# Install & Import Teams Module
Install-Module -Name MicrosoftTeams -Force -AllowClobber
Import-Module MicrosoftTeams

# Install & Import the Exchange Online module
Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline
Connect-MicrosoftTeams

# Read the CSV file
$groupList = Import-Csv -Path $csvPath

# Iterate through each row in the CSV and create shared mailboxes
foreach ($group in $groupList) {
    $displayName = $group.DisplayName
    $alias = $group.Alias
    $emailAddress = $group.EmailAddress
    # $aliasEmailAddresses = $group.EmailAddresses -split ","
    $groupType = $group.GroupType
    $AccessType = $group.AccessType
    $owners = $group.Owners -split ","
    $members = $group.Members -split ","
    $membersSendAs = $group.MembersSendAs -split ","

    $existingGroup = Get-UnifiedGroup | Where -Property EmailAddresses -like "smtp:$emailAddress"

    if ($existingGroup) {
        # Add members to the shared mailbox
        Write-Host "Unified Group $emailAddress already exists. Setting permissions."
        Write-Host "Adding members $members"
        $members | ForEach-Object {Add-UnifiedGroupLinks -Identity $emailAddress -LinkType Members -Links $_}
        Write-Host "Adding owners $owners"
        $owners | ForEach-Object {Add-UnifiedGroupLinks -Identity $emailAddress -LinkType Owners -Links $_}
        Write-Host "Applying member send as permissions."
        $membersSendAs | ForEach-Object {Add-RecipientPermission -Identity $emailAddress -AccessRights SendAs -Trustee $_ -Confirm:$false}
        Write-Host "Set permissions."
    }  else {
        Write-Host "Unified Group doesn't exist so we're adding one. Adding $emailAddress"
        if ($groupType -eq "Team") {
            $newGroup = New-Team -DisplayName $displayName -MailNickName $alias -Visibility $AccessType
            Write-Host "Changing primary smtp address to $emailAddress"
            Set-UnifiedGroup -Identity "$alias@$domainName"-PrimarySmtpAddress $emailAddress
            Write-Host "Adding members $members"
            $members | ForEach-Object {Add-TeamUser -GroupId $newGroup.GroupId -User $_}
            Write-Host "Adding owners $owners"
            $owners | ForEach-Object {Add-UnifiedGroupLinks -Identity $emailAddress -LinkType Owners -Links $_}
            Write-Host "Allow showing in Outlook."
            Set-UnifiedGroup -Identity "$emailAddress" -HiddenFromExchangeClientsEnabled:$false
            Write-Host "Group added."
    
        } else {
            Write-Host "Creating group without teams $emailAddress."
            New-UnifiedGroup -DisplayName $displayName -Alias $alias -AccessType $accessType -PrimarySmtpAddress $emailAddress -Members $group.
            $owners | ForEach-Object {Add-UnifiedGroupLinks -Identity $emailAddress -LinkType Owners -Links $_}
            $membersSendAs | ForEach-Object {Add-RecipientPermission -Identity $emailAddress -AccessRights SendAs -Trustee $_ -Confirm:$false}
            Write-Host "Group Added."
        }
    }

}

# Disconnect from Exchange Online
Disconnect-ExchangeOnline
Disconnect-MicrosoftTeams