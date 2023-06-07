## Please note this script can only support the following backup repository types ##
# S3 Compabitble & Local. Both are forced.

Start-Transcript -Path $env:WINDIR\logs\veeam-add-backup-repo.log

Write-Host "Checking if we are running from a RMM or not."

# if ($rmm -ne 1) { 
    # Set the repository details
    # $repositoryType = "Please enter the repository type (1 S3 Compatible; 2 Windows Local; 3 Both)"
    # $moveBackups = "Enter 1 if you wish to move your local backups"
    # $description = Read-Host "Please enter the ticket # or project ticket # related to this configuration"
    # $immutabilityPeriod = Read-Host "Enter how many days every object is immutable for"
    # $repositoryName = Read-Host "Enter the repository name" | Out-String
    # $accessKey = Read-Host "Enter the access key"
    # $secretKey = Read-Host "Enter the secret key"
    # $endpoint = Read-Host "Enter the S3 endpoint url"
    # $regionId = Read-Host "Enter the region ID"
    # $bucketName = Read-Host "Enter the bucket name"

# }

Write-Host "The varialbes are now set."
Write-Host "Repository type: $repositoryType"
Write-Host "Move backups: $moveBackups"
Write-Host "Description: $description"
Write-Host "Immutability period: $immutabilityPeriod"
Write-Host "Access key: $accessKey"
Write-Host "Secret key: **redacted for sensativity**"
Write-Host "S3 Endpoint: $endpoint"
Write-Host "S3 Region ID: $regionId"
Write-Host "S3 Bucket Name: $bucketName"
Write-Host "Automatic volume letter to create WinLocal repo: "
Write-Host "Drive letters to create WinLocal Repos: $driveLetters"


# Make sure PSModulePath includes Veeam Console
Write-Host "Installing Veeam PowerShell Module if not installed already."
$MyModulePath = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MyModulePath"
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

# Set Timestamp
Write-Host "Getting timestamp for repository names."
$timeStamp = [int](Get-Date -UFormat %s -Millisecond 0)
$folderName = $timeStamp


if ($repositoryType -eq 1 -Or $repositoryType -eq 3){
    Write-Host "Creating S3 Repository: S3 $timeStamp"
    # Add the S3 Account
    $account = Add-VBRAmazonAccount -AccessKey $accessKey -SecretKey $secretKey -Description "$description $bucketName"

    # Create the S3 repository
    $connect = Connect-VBRAmazonS3CompatibleService -Account $account -CustomRegionId $regionId -ServicePoint $endpoint
    $bucket = Get-VBRAmazonS3Bucket -Connection $connect -Name $bucketName
    $folder = New-VBRAmazonS3Folder -Name $folderName -Connection $connect -Bucket $bucket
    Add-VBRAmazonS3CompatibleRepository -AmazonS3Folder $folder -Connection $connect -Name "S3 $timeStamp" -EnableBackupImmutability -ImmutabilityPeriod $immutabilityPeriod -Description "$description $bucketName"
    
    # Display the added repository details
    $repository

}



if ($repositoryType -eq 2 -Or $repositoryType -eq 3){
    Write-Host "Creating local repository Local $timeStamp"
    # Get all logical drives on the system
    $drives = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }

    # Find the drive with the largest total capacity
    if ($drives.Count -gt 1){ 
        $filteredDrives = $drives | Where-Object { $_ -ne 'C:' }

    } else {
        $filteredDrives = $drives
    }

    # Create the local repository
    $filteredDrives | ForEach-Object { 
        $timeStamp = [int](Get-Date -UFormat %s -Millisecond 0)
        $repositoryPath = Join-Path -Path $_.DeviceID -ChildPath "\veeam\$timeStamp"
        $repositoryName = "Local $timeStamp"
        Write-Host "Repository name: $repositoryName"
        Write-Host "Repository path: $repositoryPath"
        New-Item -ItemType Directory -Force -Path $repoistoryPath
        $repository = Add-VBRBackupRepository -Type WinLocal -Name "$repositoryName" -Folder $_ -Description "$description"
        #  Display the added repository details
        $repository
        Start-Sleep -Seconds 1
    }
}
Stop-Transcript