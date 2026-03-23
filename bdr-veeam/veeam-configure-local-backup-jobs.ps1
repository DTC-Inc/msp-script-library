## Configures all local backup jobs (agent/VM) with a standard schedule:
##   Mon-Fri: 5 AM - 10 PM (blocked overnight for S3 copy window)
##   Sat-Sun: No local backups (S3 copy runs all day)
##
## This complements veeam-configure-s3-copy-job.ps1 which runs:
##   Mon-Fri: 10 PM - 5 AM
##   Sat-Sun: All day
##
## $env:DESCRIPTION   - Ticket # or initials for audit trail
## $env:RMM           - Set to 1 when running from RMM platform
## $env:RMM_SCRIPT_PATH - Script path provided by RMM (used for log location)

# ============================================================
# PS7 BOOTSTRAP
# ============================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { $null }
    if (-not $PWSH_PATH) { $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    if (Test-Path $PWSH_PATH) {
        Write-Host "Re-launching in PowerShell 7..."
        & $PWSH_PATH -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

# ============================================================
# INPUT HANDLING
# ============================================================

$SCRIPT_LOG_NAME = "veeam-configure-local-backup-schedule.log"
$ConfirmPreference = 'None'

if ($env:RMM -ne "1") {
    if (-not $env:DESCRIPTION) { $env:DESCRIPTION = Read-Host "Ticket # or initials" }
    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
} else {
    if (-not $env:DESCRIPTION) { $env:DESCRIPTION = "No Description" }
    if ($env:RMM_SCRIPT_PATH) {
        $LOG_DIR = "$env:RMM_SCRIPT_PATH\logs"
        if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
        $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
    } else {
        $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
    }
}

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam Local Backup Schedule Configuration ==="
Write-Host "Description: $env:DESCRIPTION"
Write-Host "Schedule:    Mon-Fri 5 AM - 10 PM"
Write-Host "             Sat-Sun disabled"
Write-Host ""

# ============================================================
# LOAD VEEAM MODULE
# ============================================================

Write-Host "Loading Veeam PowerShell module..."
$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"

if ($VBR_MODULES = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $VBR_MODULES | Import-Module -WarningAction SilentlyContinue
        Write-Host "  [OK] Veeam module loaded."
    } catch {
        Stop-Transcript
        throw "Failed to load Veeam modules: $_"
    }
} else {
    Stop-Transcript
    throw "Veeam.Backup.PowerShell module not found."
}

# ============================================================
# GET LOCAL BACKUP JOBS
# ============================================================

Write-Host ""
Write-Host "Collecting local backup jobs..."

$LOCAL_JOBS = @()

# Get regular backup jobs
try {
    $VBR_JOBS = @(Get-VBRJob -WarningAction SilentlyContinue | Where-Object {
        ($_.JobType -eq 'Backup' -or $_.JobType -eq 'EpAgentBackup' -or
         $_.JobType -eq 'EpAgentPolicy' -or $_.JobType -eq 'EpAgentManagement') -and
        -not $_.IsBackupCopy
    })
    if ($VBR_JOBS.Count -gt 0) {
        Write-Host "  Get-VBRJob: $($VBR_JOBS.Count) local backup jobs"
        $LOCAL_JOBS += $VBR_JOBS
    }
} catch {
    Write-Warning "  Get-VBRJob failed: $_"
}

# Get computer/agent backup jobs
$COMPUTER_JOBS = @()
try {
    $COMPUTER_JOBS = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
    if ($COMPUTER_JOBS.Count -gt 0) {
        Write-Host "  Get-VBRComputerBackupJob: $($COMPUTER_JOBS.Count) agent jobs"
    }
} catch {
    Write-Warning "  Get-VBRComputerBackupJob failed: $_"
}

if ($LOCAL_JOBS.Count -eq 0 -and $COMPUTER_JOBS.Count -eq 0) {
    Write-Host "  No local backup jobs found."
    Stop-Transcript
    exit 0
}

# ============================================================
# BUILD BACKUP WINDOW
# ============================================================

# Backup window string: 168 chars (24h x 7 days starting Sunday)
# 1 = allowed to run, 0 = blocked
# Sun: blocked, Mon-Fri: 5 AM (05) - 9 PM (21), Sat: blocked
$WINDOW = ""
for ($DAY = 0; $DAY -lt 7; $DAY++) {
    for ($HOUR = 0; $HOUR -lt 24; $HOUR++) {
        if ($DAY -eq 0 -or $DAY -eq 6) {
            # Sunday (0) and Saturday (6): blocked all day
            $WINDOW += "0"
        } else {
            # Mon-Fri: 5 AM through 9 PM (21:59), blocked 10 PM - 4:59 AM
            if ($HOUR -ge 5 -and $HOUR -le 21) {
                $WINDOW += "1"
            } else {
                $WINDOW += "0"
            }
        }
    }
}

# ============================================================
# CONFIGURE VBR JOBS (Get-VBRJob types)
# ============================================================

if ($LOCAL_JOBS.Count -gt 0) {
    Write-Host ""
    Write-Host "Configuring VBR job schedules..."

    foreach ($JOB in $LOCAL_JOBS) {
        Write-Host "  $($JOB.Name) ($($JOB.JobType))..."

        try {
            # Get current job options
            $OPTIONS = $JOB.GetOptions()

            # Enable backup window
            $OPTIONS.BackupTargetOptions.TransformToSyntethicDays = [Veeam.Backup.Common.EDayOfWeek]::None
            $OPTIONS.JobOptions.BackupWindowEnabled = $true
            $OPTIONS.JobOptions.BackupWindow = $WINDOW

            # Apply
            Set-VBRJobOptions -Job $JOB -Options $OPTIONS
            Write-Host "    [OK] Backup window applied."
        } catch {
            # Try Set-VBRJobSchedule as fallback
            try {
                Set-VBRJobSchedule -Job $JOB `
                    -DailyOptions (New-VBRDailyOptions -DayOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -Period 1) `
                    -At "05:00"
                Write-Host "    [OK] Schedule set (daily Mon-Fri at 5 AM)."
            } catch {
                Write-Warning "    Failed: $_"
            }
        }
    }
}

# ============================================================
# CONFIGURE COMPUTER BACKUP JOBS
# ============================================================

if ($COMPUTER_JOBS.Count -gt 0) {
    Write-Host ""
    Write-Host "Configuring agent/computer backup job schedules..."

    foreach ($JOB in $COMPUTER_JOBS) {
        Write-Host "  $($JOB.Name)..."

        try {
            Set-VBRComputerBackupJob -Job $JOB `
                -EnableSchedule `
                -BackupWindowEnabled `
                -BackupWindowOptions $WINDOW
            Write-Host "    [OK] Backup window applied."
        } catch {
            Write-Warning "    Failed to set backup window: $_"
            # Try just setting the schedule days
            try {
                Set-VBRComputerBackupJob -Job $JOB `
                    -EnableSchedule `
                    -DailySchedule `
                    -DailyType Weekdays
                Write-Host "    [OK] Fallback: set to weekdays only."
            } catch {
                Write-Warning "    Fallback also failed: $_"
            }
        }
    }
}

Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
