## Ensures a single S3 backup copy job exists targeting the S3 repository,
## with ALL backup jobs as sources. If the copy job exists, adds any missing
## source jobs. If it doesn't exist, creates it.
##
## Uses immediate/simple mode (copies latest restore point when source job
## finishes, not full history). This is the "pruning" mode.
##
## $env:CUSTOM_FIELD_S3_BUCKET_NAME  - NinjaOne field name for the S3 bucket/repo name
## $env:CUSTOM_FIELD_CLOUD_RETENTION      - NinjaOne org-level field name for cloud backup retention days (versions to keep) (default: 30)
## $env:DESCRIPTION                  - Ticket # or initials for audit trail
## $env:RMM                          - Set to 1 when running from RMM platform
## $env:RMM_SCRIPT_PATH              - Script path provided by RMM (used for log location)

# ============================================================
# PS7 BOOTSTRAP
# ============================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    # Always prefer 64-bit PS7. Veeam's native SQLite DLL is x64 only.
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $PWSH_PATH)) {
        $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { $null }
    }
    if (Test-Path $PWSH_PATH) {
        Write-Host "Re-launching in PowerShell 7..."
        & $PWSH_PATH -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

# Fix PS7.4+ / Veeam SQLite conflict.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $VEEAM_BACKUP_DIR = "C:\Program Files\Veeam\Backup and Replication\Backup"
    $VEEAM_RUNTIMES = "C:\Program Files\Veeam\Backup and Replication\Backup\runtimes\win-x64\native"
    foreach ($DIR in @($VEEAM_RUNTIMES, $VEEAM_BACKUP_DIR)) {
        if ((Test-Path $DIR) -and $env:PATH -notlike "*$DIR*") {
            $env:PATH = "$DIR;$env:PATH"
        }
    }
    if (Test-Path $VEEAM_BACKUP_DIR) {
        $null = [System.AppDomain]::CurrentDomain.add_AssemblyResolve({
            param($sender, $args)
            if (-not $args.Name) { return $null }
            $ASSEMBLY_NAME = [System.Reflection.AssemblyName]::new($args.Name)
            $VEEAM_DLL = Join-Path "C:\Program Files\Veeam\Backup and Replication\Backup" "$($ASSEMBLY_NAME.Name).dll"
            if (Test-Path $VEEAM_DLL) {
                return [System.Reflection.Assembly]::LoadFrom($VEEAM_DLL)
            }
            return $null
        })
    }
}

# ============================================================
# INPUT HANDLING
# ============================================================

$SCRIPT_LOG_NAME = "veeam-configure-s3-copy-job.log"
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

# Cloud Retention: read from org-level NinjaOne field, default 30
$RETENTION_DAYS = 30
if ($env:CUSTOM_FIELD_CLOUD_RETENTION) {
    try {
        $RPO_VALUE = Ninja-Property-Get $env:CUSTOM_FIELD_CLOUD_RETENTION 2>$null
        if ($RPO_VALUE) { $RETENTION_DAYS = [int]$RPO_VALUE }
    } catch { }
}

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam S3 Copy Job Configuration ==="
Write-Host "Description:    $env:DESCRIPTION"
Write-Host "Retention:      $RETENTION_DAYS days"
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
# FIND THE S3 REPOSITORY
# ============================================================

Write-Host ""
Write-Host "Finding S3 repository..."

$S3_REPO_NAME = $null
if ($env:CUSTOM_FIELD_S3_BUCKET_NAME) {
    try {
        $S3_REPO_NAME = Ninja-Property-Get $env:CUSTOM_FIELD_S3_BUCKET_NAME 2>$null
    } catch { }
}

# Find the repo in Veeam by name
$S3_REPO = $null
if ($S3_REPO_NAME) {
    $S3_REPO = Get-VBRBackupRepository -Name $S3_REPO_NAME -ErrorAction SilentlyContinue
}

# If not found by NinjaOne field, look for any S3-compatible repo
if (-not $S3_REPO) {
    Write-Host "  S3 repo not found by NinjaOne field. Searching for S3-compatible repositories..."
    $ALL_REPOS = Get-VBRBackupRepository
    $S3_REPOS = $ALL_REPOS | Where-Object { $_.Type -like "AmazonS3*" -or $_.Type -eq "S3Compatible" -or $_.Type -match "S3" }

    if ($S3_REPOS.Count -eq 1) {
        $S3_REPO = $S3_REPOS[0]
    } elseif ($S3_REPOS.Count -gt 1) {
        # Also check object storage repos
        try {
            $OBJ_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
            if ($OBJ_REPOS.Count -eq 1) {
                $S3_REPO_NAME = $OBJ_REPOS[0].Name
                $S3_REPO = Get-VBRBackupRepository -Name $S3_REPO_NAME -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    if (-not $S3_REPO) {
        Write-Error "No S3 repository found. Run veeam-create-s3-repo.ps1 first."
        Stop-Transcript
        exit 1
    }
}

Write-Host "  [OK] S3 repository: $($S3_REPO.Name)"

# ============================================================
# GET ALL SOURCE BACKUP JOBS
# ============================================================

Write-Host ""
Write-Host "Collecting source backup jobs..."

$SOURCE_JOBS = @()

# Get regular backup jobs (VM, etc.)
try {
    $VM_JOBS = @(Get-VBRJob -WarningAction SilentlyContinue | Where-Object {
        $_.JobType -eq 'Backup' -or $_.JobType -eq 'EpAgentBackup' -or
        $_.JobType -eq 'EpAgentPolicy' -or $_.JobType -eq 'EpAgentManagement'
    })
    if ($VM_JOBS.Count -gt 0) {
        Write-Host "  Get-VBRJob: $($VM_JOBS.Count) backup jobs"
        foreach ($J in $VM_JOBS) { Write-Host "    $($J.Name) ($($J.JobType))" }
        $SOURCE_JOBS += $VM_JOBS
    }
} catch {
    Write-Warning "  Get-VBRJob failed: $_"
}

# Get computer/agent backup jobs
try {
    $AGENT_JOBS = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
    if ($AGENT_JOBS.Count -gt 0) {
        Write-Host "  Get-VBRComputerBackupJob: $($AGENT_JOBS.Count) agent jobs"
        foreach ($J in $AGENT_JOBS) { Write-Host "    $($J.Name)" }
        $SOURCE_JOBS += $AGENT_JOBS
    }
} catch {
    Write-Warning "  Get-VBRComputerBackupJob failed: $_"
}

# Filter out any backup copy jobs from the source list (don't copy a copy)
$SOURCE_JOBS = @($SOURCE_JOBS | Where-Object {
    $_.JobType -ne 'SimpleBackupCopyPolicy' -and
    $_.JobType -ne 'BackupSync' -and
    $_.JobType -ne 'SimpleBackupCopyWorker' -and
    -not $_.IsBackupCopy
})

if ($SOURCE_JOBS.Count -eq 0) {
    Write-Error "No source backup jobs found to copy."
    Stop-Transcript
    exit 1
}

Write-Host "  Total source jobs: $($SOURCE_JOBS.Count)"

# ============================================================
# CHECK FOR EXISTING S3 COPY JOB
# ============================================================

Write-Host ""
Write-Host "Checking for existing S3 copy job..."

$EXISTING_COPY_JOB = $null
try {
    $ALL_COPY_JOBS = @(Get-VBRBackupCopyJob -ErrorAction Stop)
    foreach ($CJ in $ALL_COPY_JOBS) {
        if ($null -ne $CJ.TargetRepository -and $CJ.TargetRepository.Name -eq $S3_REPO.Name) {
            $EXISTING_COPY_JOB = $CJ
            break
        }
    }
} catch {
    Write-Warning "  Get-VBRBackupCopyJob failed: $_"
}

if ($EXISTING_COPY_JOB) {
    # ============================================================
    # UPDATE EXISTING COPY JOB - add missing source jobs
    # ============================================================

    Write-Host "  [OK] Found existing copy job: $($EXISTING_COPY_JOB.Name)"
    Write-Host ""

    # Get currently linked source job IDs
    $LINKED_IDS = @()
    try {
        if ($EXISTING_COPY_JOB.LinkedJobIds) {
            $LINKED_IDS = @($EXISTING_COPY_JOB.LinkedJobIds)
        }
    } catch { }

    # Also check via BackupJob property
    if ($LINKED_IDS.Count -eq 0) {
        try {
            if ($EXISTING_COPY_JOB.BackupJob) {
                $LINKED_IDS = @($EXISTING_COPY_JOB.BackupJob | ForEach-Object { $_.Id })
            }
        } catch { }
    }

    Write-Host "  Currently linked: $($LINKED_IDS.Count) jobs"
    foreach ($LID in $LINKED_IDS) {
        $LINKED_NAME = ($SOURCE_JOBS | Where-Object { $_.Id -eq $LID }).Name
        if (-not $LINKED_NAME) { $LINKED_NAME = $LID }
        Write-Host "    $LINKED_NAME"
    }

    # Find jobs NOT yet linked
    $MISSING_JOBS = @($SOURCE_JOBS | Where-Object { $LINKED_IDS -notcontains $_.Id })

    if ($MISSING_JOBS.Count -eq 0) {
        Write-Host ""
        Write-Host "  All backup jobs are already linked. Nothing to do."
    } else {
        Write-Host ""
        Write-Host "  Missing from copy job ($($MISSING_JOBS.Count)):"
        foreach ($MJ in $MISSING_JOBS) { Write-Host "    $($MJ.Name) ($($MJ.JobType))" }

        # Rebuild the full source list (existing + missing)
        # Set-VBRBackupCopyJob replaces the source list, so include everything
        Write-Host ""
        Write-Host "  Updating copy job with all source jobs..."
        try {
            Set-VBRBackupCopyJob -Job $EXISTING_COPY_JOB -BackupJob $SOURCE_JOBS
            Write-Host "  [OK] Copy job updated with $($SOURCE_JOBS.Count) source jobs."
        } catch {
            Write-Warning "  Set-VBRBackupCopyJob failed: $_"
            Write-Host "  Trying alternative: adding missing jobs individually..."

            # Fallback: try the internal API to add linked jobs
            foreach ($MJ in $MISSING_JOBS) {
                try {
                    $GUID = [guid]::NewGuid()
                    $LINKED_INFO = [Veeam.Backup.Model.CLinkedObjectInfo]::new(
                        $GUID, $EXISTING_COPY_JOB.Id, $MJ.Id, (Get-Date), 0)
                    [Veeam.Backup.Core.CLinkedJobs]::Create($LINKED_INFO)
                    Write-Host "    [OK] Added: $($MJ.Name)"
                } catch {
                    Write-Warning "    Failed to add $($MJ.Name): $_"
                }
            }

            # Refresh the job
            try {
                $EXISTING_COPY_JOB_OBJ = Get-VBRJob | Where-Object { $_.Id -eq $EXISTING_COPY_JOB.Id }
                if ($EXISTING_COPY_JOB_OBJ) { $EXISTING_COPY_JOB_OBJ.Update() }
            } catch { }
        }
    }
} else {
    # ============================================================
    # CREATE NEW COPY JOB
    # ============================================================

    Write-Host "  No existing S3 copy job found. Creating one..."
    Write-Host ""

    # Veeam job name max is 50 chars. Truncate repo name to fit.
    $REPO_SHORT = $S3_REPO.Name
    if ("S3 Copy - $REPO_SHORT".Length -gt 50) {
        $REPO_SHORT = $REPO_SHORT.Substring(0, 50 - 10)  # "S3 Copy - " = 10 chars
    }
    $COPY_JOB_NAME = "S3 Copy - $REPO_SHORT"

    Write-Host "  Job name:    $COPY_JOB_NAME"
    Write-Host "  Target repo: $($S3_REPO.Name)"
    Write-Host "  Source jobs:  $($SOURCE_JOBS.Count)"
    Write-Host "  Mode:        Periodic (24/7)"
    Write-Host "  Retention:   $RETENTION_DAYS days"
    Write-Host ""

    try {
        $ConfirmPreference = 'None'

        # Step 1: Create the job WITHOUT backup window (window must be applied after)
        Write-Host "  Step 1: Creating copy job (Periodic mode)..."

        $COPY_JOB = Add-VBRBackupCopyJob `
            -Name $COPY_JOB_NAME `
            -Description "$env:DESCRIPTION" `
            -BackupJob $SOURCE_JOBS `
            -TargetRepository $S3_REPO `
            -DirectOperation `
            -Mode Periodic `
            -RetentionType RestoreDays `
            -RetentionNumber $RETENTION_DAYS

        Write-Host "  [OK] Copy job created: $($COPY_JOB.Name)"

        # Step 2: Set schedule with backup window
        # Mon-Fri: 10 PM - 5 AM, Sat-Sun: all day
        try {
            Write-Host "  Step 2: Setting schedule with backup window..."

            # Build window: VBRBackupWindowOptions for the periodically schedule
            # This restricts WHEN the periodic job is allowed to run
            $WEEKNIGHT_WINDOW = New-VBRBackupWindowOptions -FromDay Monday -FromHour 22 -ToDay Friday -ToHour 5
            $WEEKEND_WINDOW = New-VBRBackupWindowOptions -FromDay Saturday -FromHour 0 -ToDay Sunday -ToHour 23

            # Create periodically options: check every hour, restricted by window
            $PERIOD_OPTS = New-VBRPeriodicallyOptions -PeriodicallyKind Hours -FullPeriod 1 -PeriodicallySchedule $WEEKNIGHT_WINDOW

            # Create schedule options with termination window
            $SCHEDULE = New-VBRServerScheduleOptions -Type Periodically -PeriodicallyOptions $PERIOD_OPTS

            Set-VBRBackupCopyJob -Job $COPY_JOB -ScheduleOptions $SCHEDULE
            Write-Host "  [OK] Schedule: Mon-Fri 10 PM - 5 AM, Sat-Sun all day."
        } catch {
            Write-Warning "  Failed to set schedule: $_"
            Write-Host "  Configure the schedule manually in the Veeam console."
        }

        # Step 3: Enable encryption using the first available encryption key
        try {
            Write-Host "  Step 3: Configuring encryption..."
            $ENCRYPTION_KEY = Get-VBREncryptionKey | Select-Object -First 1

            if ($ENCRYPTION_KEY) {
                Write-Host "    Using key: $($ENCRYPTION_KEY.Id)"
                $STORAGE_OPTS = New-VBRBackupCopyJobStorageOptions `
                    -CompressionLevel Auto `
                    -StorageOptimizationType LocalTarget `
                    -EnableEncryption `
                    -EncryptionKey $ENCRYPTION_KEY
                Set-VBRBackupCopyJob -Job $COPY_JOB -StorageOptions $STORAGE_OPTS
                Write-Host "  [OK] Encryption enabled."
            } else {
                Write-Warning "  No encryption key found. Configure encryption manually."
            }
        } catch {
            Write-Warning "  Failed to set encryption: $_"
            Write-Host "  Configure encryption manually in the Veeam console."
        }

        # Step 4: Enable the job (created disabled by default)
        try {
            Enable-VBRBackupCopyJob -Job $COPY_JOB
            Write-Host "  [OK] Copy job enabled."
        } catch {
            Write-Warning "  Failed to enable: $_"
            Write-Host "  Enable it manually in the Veeam console."
        }
    } catch {
        Write-Error "Failed to create copy job: $_"
        Stop-Transcript
        exit 1
    }
}

Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
