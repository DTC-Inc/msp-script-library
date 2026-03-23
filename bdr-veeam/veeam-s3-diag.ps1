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
Write-Host "1: ArchiveRepository + AmazonCompatibleOptions + Options + Info"
Write-Host "=========================================="
try {
    $REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    Write-Host "Found $($REPOS.Count) repos`n"

    foreach ($R in $REPOS) {
        Write-Host "--- $($R.Name) ---"

        Write-Host "`n  .ArchiveRepository:"
        if ($null -ne $R.ArchiveRepository) {
            Write-Host "    Type: $($R.ArchiveRepository.GetType().FullName)"
            $R.ArchiveRepository | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                $P = $_.Name; try { Write-Host "    $P = $($R.ArchiveRepository.$P)" } catch { Write-Host "    $P = [ERROR]" }
            }
        } else { Write-Host "    NULL" }

        Write-Host "`n  .AmazonCompatibleOptions:"
        if ($null -ne $R.AmazonCompatibleOptions) {
            Write-Host "    Type: $($R.AmazonCompatibleOptions.GetType().FullName)"
            $R.AmazonCompatibleOptions | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                $P = $_.Name; try { Write-Host "    $P = $($R.AmazonCompatibleOptions.$P)" } catch { Write-Host "    $P = [ERROR]" }
            }
        } else { Write-Host "    NULL" }

        Write-Host "`n  .Options:"
        if ($null -ne $R.Options) {
            Write-Host "    Type: $($R.Options.GetType().FullName)"
            $R.Options | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                $P = $_.Name; try { Write-Host "    $P = $($R.Options.$P)" } catch { Write-Host "    $P = [ERROR]" }
            }
        } else { Write-Host "    NULL" }

        Write-Host "`n  .Info:"
        if ($null -ne $R.Info) {
            Write-Host "    Type: $($R.Info.GetType().FullName)"
            $R.Info | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                $P = $_.Name; try { Write-Host "    $P = $($R.Info.$P)" } catch { Write-Host "    $P = [ERROR]" }
            }
        } else { Write-Host "    NULL" }

        Write-Host ""
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "`n=========================================="
Write-Host "2: Backup.GetAllStorages() on the S3 backup copy"
Write-Host "=========================================="
try {
    $B = Get-VBRBackup | Where-Object { $_.TypeToString -eq "Backup Copy" } | Select-Object -First 1
    Write-Host "Backup: $($B.Name)"
    Write-Host "RepositoryId: $($B.RepositoryId)`n"

    Write-Host "--- GetAllStorages() ---"
    $STORAGES = $B.GetAllStorages()
    Write-Host "  Count: $($STORAGES.Count)"

    if ($STORAGES.Count -gt 0) {
        $FIRST = $STORAGES | Select-Object -First 1
        Write-Host "`n  First storage - ALL properties:"
        Write-Host "  Type: $($FIRST.GetType().FullName)"
        $FIRST | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
            $P = $_.Name; try { Write-Host "    $P = $($FIRST.$P)" } catch { Write-Host "    $P = [ERROR]" }
        }

        # Try Stats sub-object
        Write-Host "`n  First storage .Stats:"
        if ($null -ne $FIRST.Stats) {
            $FIRST.Stats | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
                $P = $_.Name; try { Write-Host "    $P = $($FIRST.Stats.$P)" } catch { Write-Host "    $P = [ERROR]" }
            }
        } else { Write-Host "    NULL" }
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "`n=========================================="
Write-Host "3: Backup.GetRepository() on the S3 backup copy"
Write-Host "=========================================="
try {
    $B = Get-VBRBackup | Where-Object { $_.TypeToString -eq "Backup Copy" } | Select-Object -First 1
    $REPO = $B.GetRepository()
    Write-Host "  Type: $($REPO.GetType().FullName)"
    $REPO | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
        $P = $_.Name; try { Write-Host "  $P = $($REPO.$P)" } catch { Write-Host "  $P = [ERROR]" }
    }
} catch { Write-Host "FAILED: $_" }

Write-Host "`n=========================================="
Write-Host "4: Copy job TargetRepository sub-objects"
Write-Host "=========================================="
try {
    $CJ = (Get-VBRBackupCopyJob)[0]
    $TR = $CJ.TargetRepository
    Write-Host "Job: $($CJ.Name)"
    Write-Host "TargetRepository: $($TR.Name) ($($TR.GetType().FullName))`n"

    Write-Host "  .ArchiveRepository:"
    if ($null -ne $TR.ArchiveRepository) {
        Write-Host "    Type: $($TR.ArchiveRepository.GetType().FullName)"
        $TR.ArchiveRepository | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
            $P = $_.Name; try { Write-Host "    $P = $($TR.ArchiveRepository.$P)" } catch { Write-Host "    $P = [ERROR]" }
        }
    } else { Write-Host "    NULL" }

    Write-Host "`n  .AmazonCompatibleOptions:"
    if ($null -ne $TR.AmazonCompatibleOptions) {
        Write-Host "    Type: $($TR.AmazonCompatibleOptions.GetType().FullName)"
        $TR.AmazonCompatibleOptions | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
            $P = $_.Name; try { Write-Host "    $P = $($TR.AmazonCompatibleOptions.$P)" } catch { Write-Host "    $P = [ERROR]" }
        }
    } else { Write-Host "    NULL" }

    Write-Host "`n  .Options:"
    if ($null -ne $TR.Options) {
        Write-Host "    Type: $($TR.Options.GetType().FullName)"
        $TR.Options | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
            $P = $_.Name; try { Write-Host "    $P = $($TR.Options.$P)" } catch { Write-Host "    $P = [ERROR]" }
        }
    } else { Write-Host "    NULL" }

    Write-Host "`n  .Info:"
    if ($null -ne $TR.Info) {
        Write-Host "    Type: $($TR.Info.GetType().FullName)"
        $TR.Info | Get-Member -MemberType Property,NoteProperty | ForEach-Object {
            $P = $_.Name; try { Write-Host "    $P = $($TR.Info.$P)" } catch { Write-Host "    $P = [ERROR]" }
        }
    } else { Write-Host "    NULL" }
} catch { Write-Host "FAILED: $_" }

Write-Host "`n=========================================="
Write-Host "5: PostgreSQL direct query"
Write-Host "=========================================="
try {
    # Find psql
    $PSQL = Get-Command psql.exe -ErrorAction SilentlyContinue
    if (-not $PSQL) {
        $PG_PATHS = @(
            "C:\Program Files\PostgreSQL\15\bin\psql.exe",
            "C:\Program Files\Veeam\Backup and Replication\PostgreSQL\15\bin\psql.exe"
        )
        foreach ($PP in $PG_PATHS) {
            if (Test-Path $PP) { $PSQL = Get-Item $PP; break }
        }
    }
    if ($PSQL) {
        Write-Host "  psql found: $($PSQL.FullName)"
        Write-Host "`n  Databases:"
        & $PSQL.FullName -h localhost -U postgres -p 5432 -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>&1 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  psql not found"
        Write-Host "  Checking for PostgreSQL service..."
        Get-Service -Name "*postgres*" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    Service: $($_.Name) Status: $($_.Status)"
        }
    }
} catch { Write-Host "FAILED: $_" }
