# This script creates a backup copy job. So far this only supports creating only 1 job, and only 1 so it will exit if 1 exists. 
# Only supports S3 Compatible Storage

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

# Get timestamp
Write-Host "Getting timestamp."
$timeStamp = [int](Get-Date -UFormat %s -Millisecond 0)

# Getting input from user if not running from RMM else set variables from RMM.
if ($rmm -ne 1) {
    $validInput = 0
    # Only running if S3 Copy Job is true for this part.
    while ($validInput -ne 1) {
        $targetRepoType = Read-Host "Enter the backup copy target repo type (S3 1, WinLocal 2)"
        if ($targetRepoType -eq 2) { 
            $targetRepository = Read-Host "Enter the target WinLocal repo name"
            $validInput = 1

        } elseif ($targetRepoType -eq 1) {
            $validInput = 1

        } else {
            Write-Host "Invalid input. Please enter 1 or 2."
            $validInput = 0

        }


    }
    $logPath = "$env:WINDIR\logs\veeam-add-backup-repo.log"
    $description = Read-Host "Please enter the ticket # and your initials. Its used as the description for the job"


} else { 
    # ticketNumber from RMM is set to the description.
    # targetWinLocalRepository is the targetRepository if targetRepoType is 2.
    # targetRepoType is targetRepoType. 
    # RMMScript path is set as a 
    $logPath = "$rmmScriptPath\logs\veeam-add-backup-repo.log"
    

}


Start-Transcript -Path $logPath

if ($targetRepoType -eq 1) {
    # Find existing backup copy jobs to S3 storage. This only supports S3 Compatible and not Amazon S3, Google, or Azure.
    # We'll exit if one already exists.
    $backupCopyTarget = Get-VBRBackupCopyJob | Select -Expand Target
    $s3CompCopyJob = $backupCopyTarget | ForEach-Object {Get-VBRBackupRepository -Name $_ | Where -Property Type -eq AmazonS3Compatible}

    if ($s3CompCopyJob) {
        Write-Host "Existing S3 Copy Job exists. Exiting."
        Exit
    }   

    $targetRepository = Get-VBRBackupRepository |Where -Property Type -eq AmazonS3Compatible


} elseif ($targetRepoType -eq 2) {
    Write-Host "This script doesn't support WinLocal backup copy jobs yet."
    Exit

} else {
    Write-Host "Target repo type doesn't contain valid input. Exiting"
    Exit
}

$encryptionKey = Get-VBREncryptionKey | Sort ModificationDate -Descending | Select -First 1
$daily = New-VBRDailyOptions -DayofWeek Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday -Period 20:00
$schedule = New-VBRScheduleOptions -Type Daily -DailyOptions $daily
$storageOptions = New-VBRBackupCopyJobStorageOptions -EnableEncryption -EncryptionKey $encryptionKey -CompressionLevel Auto -EnableDataDeduplication -StorageOptimizationType Automatic
$backupJobs = Get-VBRJob | Where -Property TypeToString -ne "Backup Copy"
# $schedule = New-VBRServerScheduleOptions -Type Periodically -PeriodicallyOptions $scheduleOption -EnableRetry -RetryCount 3 -RetryTimeout 30 -EnableBackupTerminationWindow -TerminationWindow $windowOption

Write-Host "The varialbes are now set."
Write-Host "Repository target: $targetRepository"
Write-Host "Encryption key: $encryptionKey"
Write-Host "Window option: $windowOption"
Write-Host "Schedule option: $scheudleOption"
Write-Host "Storage options: $storageOptions"
Write-Host "Backup jobs: $backupJobs"
Write-Host "Schedule: $schedule"

# Add Backup copy job for all jobs.
Write-Host "Adding backup copy job for all backup jobs."
$backupCopyJob = Add-VBRBackupCopyJob -BackupJob $backupJobs -ScheduleOptions $schedule  -Description "$description" -Mode periodic -Name "S3 Copy $timestamp" -ProcessLatestAvailablePoint -RetentionNumber 30 -RetentionType RestoreDays -StorageOptions $storageOptions -TargetRepository $targetRepository  -DirectOperation

$backupCopyJob

Write-Host "Upgrading all bakup job then re-enabling"

# Upgrade VBR Backup Chain to True Per VM
Get-VBRBackup |Where -Property TypeToString -eq "Hyper-V Backup" | Upgrade-VBRBackup

# Enable all backup jobs
Get-VBRJob | Where -Property TypeToString -eq "Hyper-V Backup" | Enable-VBRJob

Stop-Transcript
