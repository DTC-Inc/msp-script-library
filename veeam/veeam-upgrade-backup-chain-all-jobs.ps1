$backups = Get-VBRBackup
Upgrade-VBRBackup -Backup $backups -Force -RunAsync