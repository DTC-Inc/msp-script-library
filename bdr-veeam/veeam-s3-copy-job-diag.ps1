# Diagnostic: step-by-step S3 copy job creation
# Run interactively on the BDR server in PS7

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $PWSH_PATH)) {
        $PWSH = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($PWSH) { $PWSH_PATH = $PWSH.Source }
    }
    if (Test-Path $PWSH_PATH) {
        & $PWSH_PATH -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

# SQLite fix
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $VEEAM_BACKUP_DIR = "C:\Program Files\Veeam\Backup and Replication\Backup"
    $VEEAM_RUNTIMES = "C:\Program Files\Veeam\Backup and Replication\Backup\runtimes\win-x64\native"
    foreach ($DIR in @($VEEAM_RUNTIMES, $VEEAM_BACKUP_DIR)) {
        if ((Test-Path $DIR) -and $env:PATH -notlike "*$DIR*") { $env:PATH = "$DIR;$env:PATH" }
    }
    if (Test-Path $VEEAM_BACKUP_DIR) {
        $null = [System.AppDomain]::CurrentDomain.add_AssemblyResolve({
            param($sender, $args)
            if (-not $args.Name) { return $null }
            $ASSEMBLY_NAME = [System.Reflection.AssemblyName]::new($args.Name)
            $VEEAM_DLL = Join-Path "C:\Program Files\Veeam\Backup and Replication\Backup" "$($ASSEMBLY_NAME.Name).dll"
            if (Test-Path $VEEAM_DLL) { return [System.Reflection.Assembly]::LoadFrom($VEEAM_DLL) }
            return $null
        })
    }
}

$ConfirmPreference = 'None'

$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"
Get-Module -ListAvailable -Name Veeam.Backup.PowerShell | Import-Module -WarningAction SilentlyContinue

Write-Host "PS Version: $($PSVersionTable.PSVersion)"
Write-Host "Process: $([System.Diagnostics.Process]::GetCurrentProcess().Path)"
Write-Host ""

# Step 1: Find S3 repo
Write-Host "=========================================="
Write-Host "Step 1: Find S3 repository"
Write-Host "=========================================="
$S3_REPO = $null
try {
    $ALL_REPOS = Get-VBRBackupRepository
    Write-Host "  Total repos: $($ALL_REPOS.Count)"
    foreach ($R in $ALL_REPOS) { Write-Host "    $($R.Name) ($($R.Type))" }
    $S3_REPO = $ALL_REPOS | Where-Object { $_.Type -like "AmazonS3*" -or $_.Type -eq "S3Compatible" -or $_.Type -match "S3" } | Select-Object -First 1
    if ($S3_REPO) { Write-Host "  [OK] S3 repo: $($S3_REPO.Name)" } else { Write-Host "  [!] No S3 repo found"; exit 1 }
} catch { Write-Host "  FAILED: $_"; exit 1 }

# Step 2: Get source jobs
Write-Host ""
Write-Host "=========================================="
Write-Host "Step 2: Get source backup jobs"
Write-Host "=========================================="
$SOURCE_JOBS = @()
try {
    $VBR_JOBS = @(Get-VBRJob -WarningAction SilentlyContinue | Where-Object {
        ($_.JobType -eq 'Backup' -or $_.JobType -eq 'EpAgentBackup' -or
         $_.JobType -eq 'EpAgentPolicy' -or $_.JobType -eq 'EpAgentManagement') -and
        -not $_.IsBackupCopy
    })
    Write-Host "  Get-VBRJob: $($VBR_JOBS.Count)"
    foreach ($J in $VBR_JOBS) { Write-Host "    $($J.Name) ($($J.JobType))" }
    $SOURCE_JOBS += $VBR_JOBS
} catch { Write-Host "  Get-VBRJob failed: $_" }
try {
    $AGENT_JOBS = @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)
    Write-Host "  Get-VBRComputerBackupJob: $($AGENT_JOBS.Count)"
    foreach ($J in $AGENT_JOBS) { Write-Host "    $($J.Name)" }
    $SOURCE_JOBS += $AGENT_JOBS
} catch { Write-Host "  Get-VBRComputerBackupJob failed: $_" }

$SOURCE_JOBS = @($SOURCE_JOBS | Where-Object {
    $_.JobType -ne 'SimpleBackupCopyPolicy' -and $_.JobType -ne 'BackupSync' -and
    $_.JobType -ne 'SimpleBackupCopyWorker' -and -not $_.IsBackupCopy
})
Write-Host "  Total source jobs: $($SOURCE_JOBS.Count)"

# Step 3: Check cmdlet parameters
Write-Host ""
Write-Host "=========================================="
Write-Host "Step 3: Add-VBRBackupCopyJob parameters"
Write-Host "=========================================="
$CMD = Get-Command Add-VBRBackupCopyJob
$CMD.Parameters.Keys | Sort-Object | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 4: Create copy job (no window)"
Write-Host "=========================================="
$JOB_NAME = "S3 Copy Diag"
# Delete existing diag job if it exists
try {
    $EXISTING = Get-VBRBackupCopyJob | Where-Object { $_.Name -eq $JOB_NAME }
    if ($EXISTING) {
        Write-Host "  Removing existing diag job..."
        Remove-VBRBackupCopyJob -Job $EXISTING -ErrorAction Stop
        Write-Host "  [OK] Removed."
    }
} catch { Write-Host "  Cleanup failed: $_" }

try {
    # Check what Mode values are valid
    Write-Host "  Mode parameter type:"
    $MODE_PARAM = (Get-Command Add-VBRBackupCopyJob).Parameters['Mode']
    Write-Host "    Type: $($MODE_PARAM.ParameterType.FullName)"
    if ($MODE_PARAM.ParameterType.IsEnum) {
        Write-Host "    Values: $([Enum]::GetNames($MODE_PARAM.ParameterType) -join ', ')"
    }
    Write-Host ""

    Write-Host "  Creating with -Mode Periodic..."
    $COPY_JOB = Add-VBRBackupCopyJob `
        -Name $JOB_NAME `
        -Description "diag" `
        -BackupJob $SOURCE_JOBS `
        -TargetRepository $S3_REPO `
        -DirectOperation `
        -Mode Periodic `
        -RetentionType RestoreDays `
        -RetentionNumber 30

    Write-Host "  [OK] Created: $($COPY_JOB.Name)"
} catch {
    Write-Host "  FAILED: $_"
    exit 1
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 5: Set-VBRBackupCopyJob -Anytime:\$false"
Write-Host "=========================================="
try {
    Set-VBRBackupCopyJob -Job $COPY_JOB -Anytime:$false
    Write-Host "  [OK]"
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 6: New-VBRBackupWindowOptions"
Write-Host "=========================================="
try {
    Write-Host "  Checking New-VBRBackupWindowOptions parameters..."
    $WIN_CMD = Get-Command New-VBRBackupWindowOptions -ErrorAction Stop
    $WIN_CMD.Parameters.Keys | Sort-Object | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    $WINDOW = New-VBRBackupWindowOptions -FromDay Monday -FromHour 22 -ToDay Friday -ToHour 5
    Write-Host "  [OK] Window object created: $($WINDOW.GetType().FullName)"
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 7: Set-VBRBackupCopyJob -BackupWindowOptions"
Write-Host "=========================================="
try {
    Write-Host "  Checking Set-VBRBackupCopyJob parameters..."
    $SET_CMD = Get-Command Set-VBRBackupCopyJob
    $SET_CMD.Parameters.Keys | Sort-Object | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    Write-Host "  Applying window..."
    Set-VBRBackupCopyJob -Job $COPY_JOB -BackupWindowOptions $WINDOW
    Write-Host "  [OK]"
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 8: Enable-VBRBackupCopyJob"
Write-Host "=========================================="
try {
    Enable-VBRBackupCopyJob -Job $COPY_JOB
    Write-Host "  [OK] Enabled."
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Done - delete the 'S3 Copy Diag' job from Veeam console when done testing"
Write-Host "=========================================="
