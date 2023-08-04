# This script sets all backup copy schedules to run daily at 10:00 PM.

# Getting input from user if not running from RMM else set variables from RMM.

Write-Host $description
Write-Host $rmmScriptPath
Write-Host $rmm

$scriptLogName = "veeam-set-backup-copy-schedule.log"

if ($rmm -ne 1) {
    $validInput = 0
    # Only running if S3 Copy Job is true for this part.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"
        $validInput = 1
    }
    $logPath = "$env:WINDIR\logs\$scriptLogName"


} else { 
    # Store the logs in the rmmScriptPath
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
    

}

Start-Transcript -Path $logPath

Write-Host "This script is being run for $description"

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


$daily = New-VBRDailyOptions -DayofWeek Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday -Period 22:00
$schedule = New-VBRScheduleOptions -Type Daily -DailyOptions $daily

Get-VBRBackupCopyJOb | ForEach-Object { $_ | Set-VBRBackupCopyJob -ScheduleOptions $schedule  -Description "$description" -Mode Periodic; Write-Host "Changed $_.Name to Daily Schedule running at 10:00 PM." }



Stop-Transcript