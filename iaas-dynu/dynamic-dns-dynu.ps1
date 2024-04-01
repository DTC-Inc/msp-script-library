# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "EnterLogNameHere.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $hostname = "Enter the hostname we're creating or updating"
        $domain = Read-Host "Enter the domain you want to use for dynamic DNS"
        $zoneID = Read-Host "Enter the Dynu zone ID where you want to change records"
        $apiKey = Read-Host "Enter the Dynu API key"
        $ipUpdatePassword = Read-Host "Enter the IP Update password from Dynu"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Output "Invalid input. Please try again."
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
        Write-Output "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }   


    
}

Start-Transcript -Path $LogPath

Write-Output "Description: $Description"
Write-Output "Log path: $LogPath"
Write-Output "RMM: $RMM"
Write-Output "Hostname: $hostname"
Write-Output "Domain: $domain"
Write-Output "API Key: *********"
Write-Output "Zone ID: $zoneID"
Write-Output "IP Update Password: *******"

# Variables need set in RMM
# $hostname, $domain, $apiKey, $zoneID, $ipUpdatePassword
$fqdn = $hostname + "." + $domain

# Check if the domain exists in Dynu using v2 API
$recordUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode($zoneID) + "/record" 
$existingRecords = Invoke-RestMethod -Method GET -Uri $recordUrl -Headers @{"API-Key" = $apiKey} | Select -Expand dnsRecords
$existingRecordId = $existingRecord | Where { $_.hostname -eq '$fqdn' } | Select -Expand id
if ($existingRecordId -eq $null) {
    # Domain doesn't exist, create new record
    $postData = @{
        nodeName = "$hostname"
        ipv4Address = "8.8.8.8"
        recordType = "A"
        state = "true"
        ttl = 60}
        
    $createUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode($zoneID) + "/record"
    Invoke-RestMethod -Method POST -Uri $createUrl -Headers @{"API-Key" = $apiKey} -Body ($postData | ConvertTo-Json) | Write-Output

    # Update record with source IP
    wget "https://api.dynu.com/nic/update?hostname=$domain&alias=$hostname&password=$ipUpdatePassword" | Write-Output

} else {
    ## *** wget METHOD *** ##
    Write-Output "DNS records already exists. Updating IP Address."
    wget "https://api.dynu.com/nic/update?hostname=$domain&alias=$hostname&password=$ipUpdatePassword" | Write-Output

    ## *** API METHOD *** ##
    # Domain exists, update the IP address
    # $postData = @{
    #    nodeName = "$hostname"
    #    ipv4Address = "$ipAddress"
    #    recordType = "A"
    #    state = "true"
    #    ttl = 60}        
    #$updateUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode(100335411) + "/record" + [System.Net.WebUtility]::UrlEncode($existingRecordId)
    #Invoke-RestMethod -Method POST -Uri $updateUrl -Headers @{"API-Key" = $apiKey} -Body ($postData | ConvertTo-Json)
}



Stop-Transcript
