# Diagnostic script - test all data extraction paths for S3 inventory
# Run on a BDR server in PS7

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    if (Test-Path $PWSH_PATH) {
        Write-Host "Re-launching in PS7..."
        & $PWSH_PATH -NonInteractive -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"
Get-Module -ListAvailable -Name Veeam.Backup.PowerShell | Import-Module -WarningAction SilentlyContinue

$ORPHAN_DAYS = 30
$ORPHAN_CUTOFF = (Get-Date).AddDays(-$ORPHAN_DAYS)

Write-Host "=========================================="
Write-Host "1: BUCKET NAME"
Write-Host "=========================================="
try {
    $COPY_JOBS = Get-VBRBackupCopyJob -ErrorAction Stop
    Write-Host "Found $($COPY_JOBS.Count) copy jobs`n"
    foreach ($CJ in $COPY_JOBS) {
        $TR = $CJ.TargetRepository
        $OPTS = $TR.AmazonCompatibleOptions
        Write-Host "--- $($CJ.Name) ---"
        Write-Host "  BucketName:   $(if ($OPTS) { $OPTS.BucketName } else { 'NULL' })"
        Write-Host "  ServicePoint: $(if ($OPTS) { $OPTS.ServicePoint } else { 'NULL' })"
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "=========================================="
Write-Host "2: SIZE + LAST BACKUP DATE (per child)"
Write-Host "=========================================="
try {
    $ALL_BACKUPS = Get-VBRBackup
    foreach ($B in $ALL_BACKUPS) {
        Write-Host "--- $($B.Name) ---"
        Write-Host "  Type: $($B.TypeToString) | RepoId: $($B.RepositoryId) | PerVm: $($B.IsTruePerVmContainer)"

        if ($B.IsTruePerVmContainer) {
            $CHILDREN = $B.FindChildBackups()
            Write-Host "  Children: $($CHILDREN.Count)"
            $TOTAL = [long]0
            foreach ($CHILD in $CHILDREN) {
                $STORAGES = $CHILD.GetAllStorages()
                $CHILD_SIZE = [long]0
                foreach ($ST in $STORAGES) {
                    try { if ($ST.Stats.BackupSize -gt 0) { $CHILD_SIZE += [long]$ST.Stats.BackupSize } } catch {}
                }
                $LATEST = $STORAGES | Sort-Object CreationTime -Descending | Select-Object -First 1
                $LATEST_DATE = if ($LATEST) { $LATEST.CreationTime.ToString("yyyy-MM-dd") } else { "N/A" }

                if ($CHILD_SIZE -ge 1GB) { $DISPLAY = "{0:N2} GB" -f ($CHILD_SIZE / 1GB) }
                elseif ($CHILD_SIZE -ge 1MB) { $DISPLAY = "{0:N2} MB" -f ($CHILD_SIZE / 1MB) }
                else { $DISPLAY = "$CHILD_SIZE B" }

                Write-Host "    $($CHILD.Name) | $($STORAGES.Count) storages | $DISPLAY | Last: $LATEST_DATE"
                $TOTAL += $CHILD_SIZE
            }
            if ($TOTAL -ge 1TB) { Write-Host "  TOTAL: $("{0:N2} TB" -f ($TOTAL / 1TB))" }
            elseif ($TOTAL -ge 1GB) { Write-Host "  TOTAL: $("{0:N2} GB" -f ($TOTAL / 1GB))" }
        }
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "=========================================="
Write-Host "3: ORPHAN DETECTION (time-based + unlinked)"
Write-Host "  Threshold: $ORPHAN_DAYS days (before $($ORPHAN_CUTOFF.ToString('yyyy-MM-dd')))"
Write-Host "=========================================="
try {
    $COPY_JOBS = Get-VBRBackupCopyJob -ErrorAction Stop
    $ALL_BACKUPS = Get-VBRBackup
    $S3_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    $S3_IDS = @{}
    foreach ($R in $S3_REPOS) { $S3_IDS[$R.Id.ToString()] = $true }

    # Active copy job IDs targeting S3
    $ACTIVE_CJ_IDS = @{}
    foreach ($CJ in $COPY_JOBS) {
        if ($null -ne $CJ.TargetRepository -and $S3_IDS.ContainsKey($CJ.TargetRepository.Id.ToString())) {
            $ACTIVE_CJ_IDS[$CJ.Id.ToString()] = $CJ.Name
            Write-Host "  Active copy job: $($CJ.Name) ($($CJ.Id))"
        }
    }

    Write-Host ""

    foreach ($B in $ALL_BACKUPS) {
        $RID = $B.RepositoryId.ToString()
        if (-not $S3_IDS.ContainsKey($RID)) { continue }
        if (-not $B.IsTruePerVmContainer) { continue }

        $IS_JOB_LINKED = $ACTIVE_CJ_IDS.ContainsKey($B.JobId.ToString())
        Write-Host "  Backup: $($B.Name) | JobId: $($B.JobId) | Linked: $IS_JOB_LINKED"

        $CHILDREN = $B.FindChildBackups()
        foreach ($CHILD in $CHILDREN) {
            $STORAGES = $CHILD.GetAllStorages()
            $LATEST = $STORAGES | Sort-Object CreationTime -Descending | Select-Object -First 1
            $LATEST_DATE = if ($LATEST) { $LATEST.CreationTime } else { $null }
            $LATEST_STR = if ($LATEST_DATE) { $LATEST_DATE.ToString("yyyy-MM-dd") } else { "N/A" }

            $PARTS = $CHILD.Name -split ' - ', 2
            $MACHINE = if ($PARTS.Count -ge 2) { $PARTS[1].Trim() } else { $CHILD.Name }

            $REASON = $null
            if (-not $IS_JOB_LINKED) {
                $REASON = "No active job"
            } elseif ($null -ne $LATEST_DATE -and $LATEST_DATE -lt $ORPHAN_CUTOFF) {
                $DAYS = [int]((Get-Date) - $LATEST_DATE).TotalDays
                $REASON = "Stale ($DAYS days)"
            }

            $STATUS = if ($REASON) { "ORPHANED - $REASON" } else { "ACTIVE" }
            Write-Host "    [$STATUS] $MACHINE | Last: $LATEST_STR"
        }
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }
