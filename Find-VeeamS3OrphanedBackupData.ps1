function Get-VeeamS3Repositories {
    param (
        [string]$RepositoryName
    )
    
    try {
        if ($RepositoryName) {
            $s3Repos = Get-VBRBackupRepository | Where-Object { 
                $_.Name -like "*$RepositoryName*" -and 
                ($_.Type -eq "AmazonS3" -or $_.Type -eq "S3Compatible" -or 
                 $_.Type -match "S3")
            }
        }
        else {
            $s3Repos = Get-VBRBackupRepository | Where-Object { 
                $_.Type -eq "AmazonS3" -or $_.Type -eq "S3Compatible" -or 
                $_.Type -match "S3"
            }
        }
        
        return $s3Repos
    }
    catch {
        Write-Error "Failed to retrieve S3 repositories: $_"
        return $null
    }
} 