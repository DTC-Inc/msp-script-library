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
Write-Host "2: SIZE (child backup storages)"
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
Write-Host "3: ORPHAN DETECTION"
Write-Host "=========================================="
try {
    $COPY_JOBS = Get-VBRBackupCopyJob -ErrorAction Stop
    $ALL_BACKUPS = Get-VBRBackup

    # Get S3 repo IDs
    $S3_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    $S3_IDS = @{}
    foreach ($R in $S3_REPOS) { $S3_IDS[$R.Id.ToString()] = $true }

    # Get active source job IDs from copy jobs
    $ACTIVE_JOB_IDS = @{}
    foreach ($CJ in $COPY_JOBS) {
        if ($null -ne $CJ.TargetRepository -and $S3_IDS.ContainsKey($CJ.TargetRepository.Id.ToString())) {
            if ($CJ.BackupJob) {
                foreach ($LJ in $CJ.BackupJob) {
                    $ACTIVE_JOB_IDS[$LJ.Id.ToString()] = $LJ.Name
                    Write-Host "  Active source job: $($LJ.Name) ($($LJ.Id))"
                }
            }
        }
    }

    # Get machine names from active source backups
    $ACTIVE_MACHINES = @{}
    foreach ($B in $ALL_BACKUPS) {
        if ($ACTIVE_JOB_IDS.ContainsKey($B.JobId.ToString())) {
            Write-Host "  Source backup: $($B.Name)"
            try {
                $OBJECTS = $B.GetObjects()
                Write-Host "    GetObjects count: $($OBJECTS.Count)"
                foreach ($OBJ in $OBJECTS) {
                    Write-Host "    Object: $($OBJ.Name)"
                    if ($OBJ.Name) { $ACTIVE_MACHINES[$OBJ.Name.ToUpper()] = $true }
                }
            } catch { Write-Host "    GetObjects failed: $_" }

            if ($B.IsTruePerVmContainer) {
                try {
                    $CHILDREN = $B.FindChildBackups()
                    foreach ($CHILD in $CHILDREN) {
                        $PARTS = $CHILD.Name -split ' - ', 2
                        if ($PARTS.Count -ge 2) {
                            $MACHINE = $PARTS[1].Trim()
                            Write-Host "    Child machine: $MACHINE"
                            $ACTIVE_MACHINES[$MACHINE.ToUpper()] = $true
                        }
                    }
                } catch { }
            }
        }
    }

    Write-Host "`n  Active machines: $($ACTIVE_MACHINES.Keys -join ', ')`n"

    # Check S3 copy children against active machines
    foreach ($B in $ALL_BACKUPS) {
        $RID = $B.RepositoryId.ToString()
        if (-not $S3_IDS.ContainsKey($RID)) { continue }
        if (-not $B.IsTruePerVmContainer) { continue }

        $CHILDREN = $B.FindChildBackups()
        foreach ($CHILD in $CHILDREN) {
            $PARTS = $CHILD.Name -split ' - ', 2
            $MACHINE = if ($PARTS.Count -ge 2) { $PARTS[1].Trim() } else { $CHILD.Name }
            $IS_ORPHAN = -not $ACTIVE_MACHINES.ContainsKey($MACHINE.ToUpper())
            $STATUS = if ($IS_ORPHAN) { "ORPHANED" } else { "ACTIVE" }
            Write-Host "  [$STATUS] $MACHINE ($($CHILD.Name))"
        }
    }
} catch { Write-Host "FAILED: $_" }
