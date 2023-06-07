# Please make sure that b2-windows.exe is in the script root. All logs and data exported is stored here.

Start-Transcript $psScriptRoot\backblaze-create-buckets.log

# Get backblaze API credentials
$userApiKey = Read-Host "Enter Key ID"
$userApiSecret = Read-Host "Enter App Key"

# Get client list
$path = Read-Host "Enter path to client list CSV file:"
$clientList = Import-Csv $path | Select-Object -Skip 1 | ForEach-Object {
     $row = $_.PSObject.Properties.Value
     $cleanedRow = $row -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
     $bucketList = "$cleanedRow-veeam-dtc"
     $bucketList
 }

# Create bucket for each client
foreach ($client in $clientList) {
     Write-Host "Creating bucket: $client"
     .\$psScriptRoot\b2-windows.exe authorize-account $userApiKey $userApiSecret
     .\$psScriptRoot\b2-windows.exe create-bucket --defaultServerSideEncryptionAlgorithm "AES256" --defaultServerSideEncryption "SSE-B2" --fileLockEnabled $client "allPrivate" 
     $keyOut = .\b2-windows.exe create-key $client "listAllBucketNames,listBuckets,readBuckets,readBucketEncryption,writeBucketEncryption, readBucketRetentions,writeBucketRetentions,listFiles,readFiles,shareFiles,writeFiles, deleteFiles,readFileLegalHolds,writeFileLegalHolds,readFileRetentions,writeFileRetentions,bypassGovernance" --bucket $client
     Write-Host $client " " $keyOut
     $keyId, $keyApp = $keyOut -split '\s+'
     $data = [PSCustomObject]@{
        BucketName = $client 
        KeyId = $keyId
        KeyApp = $keyApp
     }

     $data | Export-Csv -Path "bucket-info.csv" -NoTypeInformation -Append

}
Stop-Transcript 
