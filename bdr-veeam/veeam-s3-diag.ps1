# Diagnostic script - test bucket name + size extraction from Veeam
# Run on a BDR server in PS7 to validate which properties return data

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
Write-Host "1: BUCKET NAME (confirmed path)"
Write-Host "=========================================="
try {
    $COPY_JOBS = Get-VBRBackupCopyJob -ErrorAction Stop
    Write-Host "Found $($COPY_JOBS.Count) copy jobs`n"
    foreach ($CJ in $COPY_JOBS) {
        $TR = $CJ.TargetRepository
        Write-Host "--- $($CJ.Name) ---"
        Write-Host "  Target repo: $($TR.Name)"

        $OPTS = $TR.AmazonCompatibleOptions
        if ($null -ne $OPTS) {
            Write-Host "  BucketName:    $($OPTS.BucketName)"
            Write-Host "  ServicePoint:  $($OPTS.ServicePoint)"
            Write-Host "  RegionId:      $($OPTS.RegionId)"
            Write-Host "  FolderName:    $($OPTS.FolderName)"
        } else {
            Write-Host "  AmazonCompatibleOptions: NULL"
        }
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "=========================================="
Write-Host "2: SIZE - Child backups (TruePerVmContainer)"
Write-Host "=========================================="
try {
    $ALL_BACKUPS = Get-VBRBackup
    Write-Host "Total backups: $($ALL_BACKUPS.Count)`n"

    foreach ($B in $ALL_BACKUPS) {
        Write-Host "--- $($B.Name) ---"
        Write-Host "  Type: $($B.TypeToString)"
        Write-Host "  RepositoryId: $($B.RepositoryId)"
        Write-Host "  IsTruePerVmContainer: $($B.IsTruePerVmContainer)"

        # Direct storages
        $STORAGES = $B.GetAllStorages()
        Write-Host "  GetAllStorages count: $($STORAGES.Count)"

        # Child backups
        if ($B.IsTruePerVmContainer) {
            try {
                $CHILDREN = $B.FindChildBackups()
                Write-Host "  FindChildBackups count: $($CHILDREN.Count)"

                $TOTAL_SIZE = [long]0
                foreach ($CHILD in $CHILDREN) {
                    $CHILD_STORAGES = $CHILD.GetAllStorages()
                    $CHILD_SIZE = [long]0
                    foreach ($ST in $CHILD_STORAGES) {
                        # Try every known size property
                        $ST_SIZE = [long]0
                        try { if ($ST.Stats -and $ST.Stats.BackupSize -gt 0) { $ST_SIZE = [long]$ST.Stats.BackupSize } } catch {}
                        if ($ST_SIZE -eq 0) { try { if ($ST.BackupSize -gt 0) { $ST_SIZE = [long]$ST.BackupSize } } catch {} }
                        if ($ST_SIZE -eq 0) { try { if ($ST.DataSize -gt 0) { $ST_SIZE = [long]$ST.DataSize } } catch {} }
                        $CHILD_SIZE += $ST_SIZE
                    }
                    if ($CHILD_STORAGES.Count -gt 0) {
                        Write-Host "    Child: $($CHILD.Name) | Storages: $($CHILD_STORAGES.Count) | Size: $CHILD_SIZE"

                        # Dump first storage properties on first child with data
                        if ($TOTAL_SIZE -eq 0 -and $CHILD_STORAGES.Count -gt 0) {
                            $FIRST_ST = $CHILD_STORAGES | Select-Object -First 1
                            Write-Host "      First storage type: $($FIRST_ST.GetType().FullName)"
                            $FIRST_ST | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                                $P = $_.Name; try { Write-Host "      $P = $($FIRST_ST.$P)" } catch { Write-Host "      $P = [ERROR]" }
                            }
                            if ($null -ne $FIRST_ST.Stats) {
                                Write-Host "      .Stats properties:"
                                $FIRST_ST.Stats | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                                    $P = $_.Name; try { Write-Host "        $P = $($FIRST_ST.Stats.$P)" } catch { Write-Host "        $P = [ERROR]" }
                                }
                            }
                        }
                    }
                    $TOTAL_SIZE += $CHILD_SIZE
                }
                Write-Host "  TOTAL child backup size: $TOTAL_SIZE bytes"
                if ($TOTAL_SIZE -gt 0) {
                    if ($TOTAL_SIZE -ge 1TB) { Write-Host "  Formatted: $("{0:N2} TB" -f ($TOTAL_SIZE / 1TB))" }
                    elseif ($TOTAL_SIZE -ge 1GB) { Write-Host "  Formatted: $("{0:N2} GB" -f ($TOTAL_SIZE / 1GB))" }
                    else { Write-Host "  Formatted: $("{0:N2} MB" -f ($TOTAL_SIZE / 1MB))" }
                }
            } catch { Write-Host "  FindChildBackups FAILED: $_" }
        } elseif ($STORAGES.Count -gt 0) {
            # Non-container backup with direct storages
            $DIRECT_SIZE = [long]0
            foreach ($ST in $STORAGES) {
                try { if ($ST.Stats -and $ST.Stats.BackupSize -gt 0) { $DIRECT_SIZE += [long]$ST.Stats.BackupSize } } catch {}
            }
            Write-Host "  Direct storage size: $DIRECT_SIZE bytes"
        }
        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }
