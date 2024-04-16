## This is a function library script for Amazon S3

# Install AWS S3 Module
Install-Module -Name AWS.Tools.Installer
Install-AWSToolsModule -Name AWS.Tools.S3


# Function to Download S3 Object
function Download-S3Object {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessKey,
        
        [Parameter(Mandatory = $true)]
        [string]$SecretKey,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [string]$BucketName,

        [Parameter(Mandatory = $true)]
        [string]$ObjectKey,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    # Setting AWS credentials and region
    Set-AWSCredential -AccessKey $AccessKey -SecretKey $SecretKey -StoreAs MyAWSCreds
    Initialize-AWSDefaults -ProfileName MyAWSCreds -Region $Region

    # Downloading the object
    try {
        Write-Host "Attempting to download '$ObjectKey' from bucket '$BucketName'."
        Read-S3Object -BucketName $BucketName -Key $ObjectKey -File $FilePath
        Write-Host "Download completed successfully. File saved to '$FilePath'."
    }
    catch {
        Write-Host "Error downloading object: $_"
    }
}

# Function to upload an S3 Object
function Upload-S3Object {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessKey,
        
        [Parameter(Mandatory = $true)]
        [string]$SecretKey,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [string]$BucketName,

        [Parameter(Mandatory = $true)]
        [string]$ObjectKey,

        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    # Setting AWS credentials and region
    Set-AWSCredential -AccessKey $AccessKey -SecretKey $SecretKey -StoreAs MyAWSCreds
    Initialize-AWSDefaults -ProfileName MyAWSCreds -Region $Region

    # Uploading the file to S3
    try {
        Write-Host "Attempting to upload '$FilePath' to bucket '$BucketName' as '$ObjectKey'."
        Write-S3Object -BucketName $BucketName -Key $ObjectKey -File $FilePath -CannedACLName 'private'
        Write-Host "Upload completed successfully."
    }
    catch {
        Write-Host "Error uploading file: $_"
    }
}
