# Please make sure that b2-windows.exe is in the script root. All logs and data exported is stored here.

# This script only works with interactive input. It does not support RMM.

# global variables
$lifecycleRules = @'
[{
     "daysFromHidingToDeleting": 1,
     "daysFromUploadingToHiding": null,
     "fileNamePrefix": ""
}]
'@

if ($rmm -ne 1) {
     Start-Transcript $psScriptRoot\backblaze-create-buckets.log
     $filePath = Join-Path -Path $psScriptRoot -ChildPath "b2-windows.exe"

     if (-not (Test-Path -Path $filePath)) {
         $url = "https://github.com/DTC-Inc/msp-script-library/blob/main/iaas-backblaze/b2-windows.exe"  # Replace with the actual download URL
     
         Write-Host "Downloading file..."
         $webClient = New-Object System.Net.WebClient
         $webClient.DownloadFile($url, $filePath)
         Write-Host "File downloaded successfully."
     } else {
         Write-Host "File already exists."
     }
     $userApiKey = Read-Host "Enter API Key ID"
     $userApiSecret = Read-Host "Enter API App Key"
     $clientListFile = Read-Host "Enter 1 if you want to import the client list via CSV file"
     if ($clientListFile -eq 1) {
          # Get client list
          $path = Read-Host "Enter path to client list CSV file:"
          $clientList = Import-Csv $path | Select-Object -Skip 1 | ForEach-Object {
               $row = $_.PSObject.Properties.Value
               $cleanedRow = $row -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
               $bucketList = "veeam-dtc-$cleanedRow"
               $bucketList
          }
      } else {
          $clientList = Read-Host "Enter clients comma separated. Enter them exactly as is in your PSA" | ForEach-Object {
               $row = $_.PSObject.Properties.Value
               $cleanedRow = $row -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
               $bucketList = "veeam-dtc-$cleanedRow"
               $bucketList
          }
     }

     # Create bucket for each client
     foreach ($client in $clientList) {
          Write-Host "Creating bucket: $client"
          & $psScriptRoot\b2-windows.exe authorize-account $userApiKey $userApiSecret
          & $psScriptRoot\b2-windows.exe create-bucket --defaultServerSideEncryptionAlgorithm "AES256" --defaultServerSideEncryption "SSE-B2" --fileLockEnabled $client "allPrivate" --lifecycleRules $lifecycleRules
          $keyOut = .\b2-windows.exe create-key $client "listAllBucketNames,listBuckets,readBuckets,readBucketEncryption,writeBucketEncryption, readBucketRetentions,writeBucketRetentions,listFiles,readFiles,shareFiles,writeFiles, deleteFiles,readFileLegalHolds,writeFileLegalHolds,readFileRetentions,writeFileRetentions,bypassGovernance" --bucket $client
          Write-Host $client " " $keyOut
          $keyId, $keyApp = $keyOut -split '\s+'
          $data = [PSCustomObject]@{
               BucketName = $client 
               KeyId = $keyId
               KeyApp = $keyApp
          }

     $data | Export-Csv -Path "$psScriptRoot\bucket-info.csv" -NoTypeInformation -Append
     }
Stop-Transcript

} else {
     Start-Transcript -Path $rmmScriptPath\logs\backblaze-create-buckets.log

     $client = $client -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }

     Write-Host "Bucket name: $client"
     Write-Host "RMM Script Path: $rmmScriptPath"
     Write-Host "Access key: $userApiKey"
     Write-Host "Secret key: **redacted for sensativity**"

     $filePath = Join-Path -Path $rmmScriptPath -ChildPath "b2-windows.exe"
     
     if (-not (Test-Path -Path $filePath)) {    
         $url = "https://repo.dtctoday.com/file/public-dtc/scripts/b2-windows.exe"  # Replace with the actual download URL
     
         Write-Host "Downloading file..."
         wget $url -OutFile $filePath
         Write-Host "File downloaded successfully."
     } else {
         Write-Host "File already exists."
     }

     $bucketName = "veeam-dtc-$client"
     Write-Host "Creating bucket: $bucketName"
     & "$rmmScriptPath\b2-windows.exe" authorize-account $userApiKey $userApiSecret
     & "$rmmScriptPath\b2-windows.exe" create-bucket --defaultServerSideEncryptionAlgorithm "AES256" --defaultServerSideEncryption "SSE-B2" --fileLockEnabled $bucketName "allPrivate" 
     $keyOut = & "$rmmScriptPath\b2-windows.exe" create-key $bucketName "listAllBucketNames,listBuckets,readBuckets,readBucketEncryption,writeBucketEncryption, readBucketRetentions,writeBucketRetentions,listFiles,readFiles,shareFiles,writeFiles, deleteFiles,readFileLegalHolds,writeFileLegalHolds,readFileRetentions,writeFileRetentions,bypassGovernance" --bucket $bucketName
     Write-Host $bucketName " " $keyOut
     $keyId, $keyApp = $keyOut -split '\s+'
     
     Write-Host "API Key ID: $keyId"
     Write-Host "API Key App: $keyApp"
     Stop-Transcript
}


