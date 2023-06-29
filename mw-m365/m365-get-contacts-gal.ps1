# Import the Exchange Online module
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline

# Specify the path to save the CSV file
$csvPath = "C:\contacts-gal.csv"

# Get all contacts from the GAL, excluding synced contacts
$contacts = Get-Contact -ResultSize Unlimited | Where-Object { $_.WhenCreated -ne $null }

# Export the contacts to a CSV file
$contacts | Export-Csv -Path $csvPath -NoTypeInformation

# Disconnect from Exchange Online
Disconnect-ExchangeOnline
