# This script sets all backup copy schedules to run daily at 10:00 PM.

## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description   / $env:description   - Ticket # and/or initials, used as the job description
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

Write-Host $description
Write-Host $rmmScriptPath

$scriptLogName = "veeam-set-backup-copy-schedule.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# The description is required: it is the audit-trail tag written onto every job. There is no
# prompt fallback, so fail fast if it was not supplied as a -Parameter or $env: variable.
if ([string]::IsNullOrEmpty($description)) {
    Write-Error "ERROR: Required input 'description' not provided (set as -Parameter or `$env:description). It is used as the description for the job."
    exit 1
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
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

Get-VBRBackupCopyJOb | ForEach-Object { $_ | Set-VBRBackupCopyJob -ScheduleOptions $schedule  -Description "$description" -Mode Periodic; Write-Host "Changed $_ to Daily Schedule running at 10:00 PM." }



Stop-Transcript
