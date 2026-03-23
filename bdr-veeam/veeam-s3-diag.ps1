# Diagnostic script - test all data extraction paths for S3 inventory + orphan detection
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
Write-Host "2: ALL ACTIVE JOBS"
Write-Host "=========================================="
$ACTIVE_JOB_IDS = @{}
try {
    $ALL_JOBS = @(Get-VBRJob -WarningAction SilentlyContinue)
    Write-Host "Get-VBRJob: $($ALL_JOBS.Count)"
    foreach ($J in $ALL_JOBS) {
        $ACTIVE_JOB_IDS[$J.Id.ToString()] = $true
        Write-Host "  $($J.Name) ($($J.JobType)) - $($J.Id)"
    }
} catch { Write-Host "Get-VBRJob FAILED: $_" }
try {
    $COPY_JOBS2 = @(Get-VBRBackupCopyJob -ErrorAction Stop)
    Write-Host "Get-VBRBackupCopyJob: $($COPY_JOBS2.Count)"
    foreach ($CJ in $COPY_JOBS2) {
        $ACTIVE_JOB_IDS[$CJ.Id.ToString()] = $true
        Write-Host "  $($CJ.Name) - $($CJ.Id)"
    }
} catch { Write-Host "Get-VBRBackupCopyJob FAILED: $_" }
try {
    $COMPUTER_JOBS = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
    Write-Host "Get-VBRComputerBackupJob: $($COMPUTER_JOBS.Count)"
    foreach ($J in $COMPUTER_JOBS) {
        $ACTIVE_JOB_IDS[$J.Id.ToString()] = $true
        Write-Host "  $($J.Name) - $($J.Id)"
    }
} catch { Write-Host "Get-VBRComputerBackupJob FAILED: $_" }
Write-Host "Total active job IDs: $($ACTIVE_JOB_IDS.Count)`n"

Write-Host "=========================================="
Write-Host "3: ORPHAN DETECTION (all repos, time + unlinked)"
Write-Host "  Threshold: $ORPHAN_DAYS days (before $($ORPHAN_CUTOFF.ToString('yyyy-MM-dd')))"
Write-Host "=========================================="

# Repo name lookup
$REPO_NAMES = @{}
try {
    $ALL_REPOS = @(Get-VBRBackupRepository)
    foreach ($R in $ALL_REPOS) { $REPO_NAMES[$R.Id.ToString()] = $R.Name }
} catch { }
try {
    $S3_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    foreach ($R in $S3_REPOS) { $REPO_NAMES[$R.Id.ToString()] = $R.Name }
} catch { }

try {
    $ALL_BACKUPS = Get-VBRBackup
    Write-Host "Total backups: $($ALL_BACKUPS.Count)`n"

    foreach ($B in $ALL_BACKUPS) {
        $RID = $B.RepositoryId.ToString()
        $REPO_NAME = if ($REPO_NAMES.ContainsKey($RID)) { $REPO_NAMES[$RID] } else { $RID.Substring(0, 8) }
        $JOB_EXISTS = $ACTIVE_JOB_IDS.ContainsKey($B.JobId.ToString())

        Write-Host "--- $($B.Name) ---"
        Write-Host "  Type: $($B.TypeToString) | Repo: $REPO_NAME | JobId: $($B.JobId) | JobExists: $JOB_EXISTS | PerVm: $($B.IsTruePerVmContainer)"

        $ENTRIES = @($B)
        if ($B.IsTruePerVmContainer) {
            try {
                $CHILDREN = $B.FindChildBackups()
                if ($CHILDREN) { $ENTRIES = @($CHILDREN) }
                Write-Host "  Children: $($CHILDREN.Count)"
            } catch { }
        }

        foreach ($E in $ENTRIES) {
            $STORAGES = @()
            try { $STORAGES = @($E.GetAllStorages()) } catch { }
            $LATEST = $STORAGES | Sort-Object CreationTime -Descending | Select-Object -First 1
            $LATEST_DATE = if ($LATEST) { $LATEST.CreationTime } else { $null }
            $LATEST_STR = if ($LATEST_DATE) { $LATEST_DATE.ToString("yyyy-MM-dd") } else { "N/A" }

            $MACHINE = $E.Name
            if ($MACHINE -match '\\(.+?) - (.+)$') { $MACHINE = $Matches[2].Trim() }
            elseif ($MACHINE -match ' - (.+)$') { $MACHINE = $Matches[1].Trim() }

            $REASON = $null
            if (-not $JOB_EXISTS) {
                $REASON = "No active job"
            } elseif ($null -ne $LATEST_DATE -and $LATEST_DATE -lt $ORPHAN_CUTOFF) {
                $DAYS = [int]((Get-Date) - $LATEST_DATE).TotalDays
                $REASON = "Stale ($DAYS days)"
            }

            $STATUS = if ($REASON) { "ORPHANED - $REASON" } else { "ACTIVE" }
            $SIZE_STR = if ($STORAGES.Count -gt 0) { "$($STORAGES.Count) storages" } else { "0 storages" }
            Write-Host "    [$STATUS] $MACHINE | $SIZE_STR | Last: $LATEST_STR | Repo: $REPO_NAME"
        }
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }
