## Please note this script can only support the following backup repository types ##
# S3 Compabitble & Local

Start-Transcript 
# Set the repository details

$repositoryType = "Please enter the repository type (1 S3; 2 Local)"
$description = Read-Host "Please enter the ticket # or project ticket # related to this configuration" | Out-String
$immutabilityPeriod = Read-Host "Enter how many days every object is immutable for"
$repositoryName = Read-Host "Enter the repository name" | Out-String
$accessKey = Read-Host "Enter the access key" | Out-String
$secretKey = Read-Host "Enter the secret key" | Out-String
$endpoint = Read-Host "Enter the S3 endpoint url" | Out-String
$regionId = Read-Host "Enter the region ID" | Out-String
$bucketName = Read-Host "Enter the bucket name" | Out-String
$folderName = Read-Host "Enter the folder name" | Out-String

# Add the S3 Account
$account = Add-VBRAmazonAccount -AccessKey $accessKey -SecretKey $secretKey -Description $description

# Create the S3 repository
$connect = Connect-VBRAmazonS3CompatibleService -Account $account -CustomRegionId "us-west-2" -ServicePoint $endpoint
$bucket = Get-VBRAmazonS3Bucket -Connection $connect -Name $bucketName
$folder = New-VBRAmazonS3Folder -Name $folderName -Connection $connect -Bucket $bucket
Add-VBRAmazonS3CompatibleRepository -AmazonS3Folder $folder -Connection $connect -Name $repositoryName -EnableBackupImmutability -ImmutabilityPeriod



# Display the added repository details
$repository

Stop-Transcript