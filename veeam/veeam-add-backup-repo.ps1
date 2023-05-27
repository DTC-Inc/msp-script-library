## Please note this script can only support the following backup repository types ##
# S3 Compabitble & Local

Start-Transcript 

$repositoryType = "Please enter the repository type (1 S3; 2 Local)"

$description = Read-Host "Please enter the ticket # or project ticket # related to this configuration" | Out-String

$immutabilityPeriod = Read-Host "Enter how many days every object is immutable for"

# Set the S3-compatible repository details
$repositoryName = "backblaze provided by dtc"
$accessKey = "0027d5671c7a12400000000c4"
$secretKey = "K002x7G9RGlnlpnwp4TFMO19jafnfQ4"
$endpoint = "https://s3.us-west-002.backblazeb2.com"
$bucketName = "silvaggiochristian-veeam-dtc"
$folderName = "441"

# Add the S3 Account
$account = Add-VBRAmazonAccount -AccessKey $accessKey -SecretKey $secretKey -Description $description

# Create the S3 repository
$connect = Connect-VBRAmazonS3CompatibleService -Account $account -CustomRegionId "us-west-2" -ServicePoint "https://s3.us-west-002.backblazeb2.com"
$bucket = Get-VBRAmazonS3Bucket -Connection $connect -Name $bucketName
$folder = New-VBRAmazonS3Folder -Name $folderName -Connection $connect -Bucket $bucket
Add-VBRAmazonS3CompatibleRepository -AmazonS3Folder $folder -Connection $connect -Name $repositoryName -EnableBackupImmutability -ImmutabilityPeriod



# Display the added repository details
$repository

Stop-Transcript