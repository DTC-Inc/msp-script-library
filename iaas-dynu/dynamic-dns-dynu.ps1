## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description       / $env:Description       - Ticket # or initials for audit trail (default: "No Description")
## $hostname          / $env:hostname          - Hostname we're creating or updating
## $domain            / $env:domain            - Domain to use for dynamic DNS
## $zoneID            / $env:zoneID            - Dynu zone ID where records are changed
## $apiKey            / $env:apiKey            - Dynu API key
## $ipUpdatePassword  / $env:ipUpdatePassword  - IP Update password from Dynu
## $RMMScriptPath     / $env:RMMScriptPath     - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description      = $env:Description,
    [string]$hostname         = $env:hostname,
    [string]$domain           = $env:domain,
    [string]$zoneID           = $env:zoneID,
    [string]$apiKey           = $env:apiKey,
    [string]$ipUpdatePassword = $env:ipUpdatePassword,
    [string]$RMMScriptPath    = $env:RMMScriptPath
)

$ScriptLogName = "dynu-dynamic-dns.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Preserve the original default for the audit-trail description.
if ([string]::IsNullOrEmpty($Description)) {
    Write-Output "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Output "Description: $Description"
Write-Output "Log path: $LogPath"
Write-Output "Hostname: $hostname"
Write-Output "Domain: $domain"
Write-Output "API Key: *********"
Write-Output "Zone ID: $zoneID"
Write-Output "IP Update Password: *******"

# Variables need set in RMM
# $hostname, $domain, $apiKey, $zoneID, $ipUpdatePassword
$fqdn = $hostname + "." + $domain
Write-Output "FQDN: $fqdn"

# Check if the domain exists in Dynu using v2 API
# $recordUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode($zoneID) + "/record"
# $existingRecords = Invoke-RestMethod -Method GET -Uri $recordUrl -Headers @{"API-Key" = $apiKey} -UseBasicParsing | Select -Expand dnsRecords
# $existingRecordId = $existingRecord | Where { $_.hostname -eq '$fqdn' } | Select -Expand id
$existingRecord = wget "https://api.dynu.com/nic/update?hostname=$domain&alias=$hostname&password=$ipUpdatePassword" -UseBasicParsing
Write-Output $existingRecord.Content

if ($existingRecord.Content -notlike "good*") {
    # Domain doesn't exist, create new record
    $postData = @{
        nodeName = "$hostname"
        ipv4Address = "8.8.8.8"
        recordType = "A"
        state = "true"
        ttl = 60}

    $createUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode($zoneID) + "/record"
    Invoke-RestMethod -Method POST -Uri $createUrl -Headers @{"API-Key" = $apiKey} -Body ($postData | ConvertTo-Json) -UseBasicParsing | Write-Output

    # Update record with source IP
    Write-Output "Updating new record $fqdn."
    $newRecord = wget "https://api.dynu.com/nic/update?hostname=$domain&alias=$hostname&password=$ipUpdatePassword" -UseBasicParsing
    Write-Output "New record response: $($newRecord.Content)"

} else {
    ## *** wget METHOD *** ##
    Write-Output "DNS records already exists. Record was already updated during the check, here is the response: $($existingRecord.Content)"


    ## *** API METHOD *** ##
    # Domain exists, update the IP address
    # $postData = @{
    #    nodeName = "$hostname"
    #    ipv4Address = "$ipAddress"
    #    recordType = "A"
    #    state = "true"
    #    ttl = 60}
    #$updateUrl = "https://api.dynu.com/v2/dns/" + [System.Net.WebUtility]::UrlEncode($zoneID) + "/record" + [System.Net.WebUtility]::UrlEncode($existingRecordId)
    #Invoke-RestMethod -Method POST -Uri $updateUrl -Headers @{"API-Key" = $apiKey} -Body ($postData | ConvertTo-Json)
}



Stop-Transcript
