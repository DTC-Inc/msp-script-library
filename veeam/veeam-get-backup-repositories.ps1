# Get Backup Jobs
Write-Host "Getting Backup Repositories."
Get-VBRBackupRepository

Write-Host "Getting Scale Out Backup Repositories"
Get-VBRBackupRepository -ScaleOut