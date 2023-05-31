$targetRepository = Get-VBRBackupRepository | Out-GridView -Title "Select your backup copy repository" -OutputMode Single
$encryptionKey = Get-VBREncryptionKey | Out-GridView -Title "Select the encryption key (use the one that's most recent or documented)" -OutputMode Single

$windowOption = New-VBRBackupWindowOptions -FromDay Monday -FromHour 06 -ToDay Saturday -ToHour 20
$scheduleOption = New-VBRPeriodicallyOPtions -FullPeriod 1 -PeriodicallyKind Hours -PeriodicallySchedule $windowOption
$storageOptions = New-VBRBackupCopyJobStorageOptions -EnableEncryption -EncryptionKey $encryptionKey -CompressionLevel Auto -EnableDataDeduplication -StorageOptimizationType Automatic
$backupJobs = Get-VBRJob | Where -Property Type -ne "Backup Copy"
$schedule = New-VBRServerScheduleOptions -Type Periodically -PeriodicallyOptions $scheduleOption -EnableRetry -RetryCount 3 -RetryTimeout 30 -EnableBackupTerminationWindow -TerminationWindow $windowOption


$targetRepository = Get-VBRBackupRepository | Out-GridView -Title "Select your backup copy repository" -OutputMode Single

Add-VBRBackupCopyJob -BackupJob $backupJobs -ScheduleOptions $schedule  -Description "$description" -Mode periodic -Name "S3 Copy $timestamp" -ProcessLatestAvailablePoint -RetentionNumber 30 -RetentionType RestoreDays -StorageOptions $storageOptions -TargetRepository $targetRepository


Add-VBRBackupCopyJob -BackupJob $backupJobs -ScheduleOptions $schedule  -Description "$description" -Mode periodic -Name "S3 Copy $timestamp" -ProcessLatestAvailablePoint -RetentionNumber 30 -RetentionType RestoreDays -StorageOptions $storageOptions -TargetRepository $targetRepository  -DirectOperation