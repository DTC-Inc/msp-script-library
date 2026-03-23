# Diagnostic: periodic copy job schedule options
# Run interactively on the BDR server in PS7

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $PWSH_PATH) {
        & $PWSH_PATH -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

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
            $AN = [System.Reflection.AssemblyName]::new($args.Name)
            $DLL = Join-Path "C:\Program Files\Veeam\Backup and Replication\Backup" "$($AN.Name).dll"
            if (Test-Path $DLL) { return [System.Reflection.Assembly]::LoadFrom($DLL) }
            return $null
        })
    }
}

$ConfirmPreference = 'None'
$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"
Get-Module -ListAvailable -Name Veeam.Backup.PowerShell | Import-Module -WarningAction SilentlyContinue

Write-Host "=========================================="
Write-Host "Schedule-related cmdlets"
Write-Host "=========================================="
Get-Command -Module Veeam.Backup.PowerShell -Name "*Schedule*","*Daily*","*Periodical*","*Window*" | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.Name)"
}

Write-Host ""
Write-Host "=========================================="
Write-Host "New-VBRServerScheduleOptions params"
Write-Host "=========================================="
try {
    $CMD = Get-Command New-VBRServerScheduleOptions -ErrorAction Stop
    $CMD.Parameters.Keys | Sort-Object | ForEach-Object {
        $P = $CMD.Parameters[$_]
        Write-Host "  $_ ($($P.ParameterType.Name))"
    }
} catch { Write-Host "  Not found: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "New-VBRDailyOptions params"
Write-Host "=========================================="
try {
    $CMD = Get-Command New-VBRDailyOptions -ErrorAction Stop
    $CMD.Parameters.Keys | Sort-Object | ForEach-Object {
        $P = $CMD.Parameters[$_]
        Write-Host "  $_ ($($P.ParameterType.Name))"
    }
} catch { Write-Host "  Not found: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Add-VBRBackupCopyJob ScheduleOptions param type"
Write-Host "=========================================="
try {
    $CMD = Get-Command Add-VBRBackupCopyJob
    $P = $CMD.Parameters['ScheduleOptions']
    if ($P) {
        Write-Host "  Type: $($P.ParameterType.FullName)"
        if ($P.ParameterType.IsEnum) {
            Write-Host "  Values: $([Enum]::GetNames($P.ParameterType) -join ', ')"
        }
    } else {
        Write-Host "  ScheduleOptions parameter not found"
    }
    $P2 = $CMD.Parameters['PeriodicallyOptions']
    if ($P2) {
        Write-Host "  PeriodicallyOptions Type: $($P2.ParameterType.FullName)"
    }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Existing copy job schedule (if any)"
Write-Host "=========================================="
try {
    $COPY_JOBS = Get-VBRBackupCopyJob
    foreach ($CJ in $COPY_JOBS) {
        Write-Host "  $($CJ.Name):"
        Write-Host "    Mode: $($CJ.Mode)"
        Write-Host "    ScheduleOptions: $($CJ.ScheduleOptions)"
        if ($CJ.ScheduleOptions) {
            $CJ.ScheduleOptions | Get-Member -MemberType Property | ForEach-Object {
                $PN = $_.Name
                try { Write-Host "      $PN = $($CJ.ScheduleOptions.$PN)" } catch {}
            }
        }
    }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Try creating schedule objects"
Write-Host "=========================================="

Write-Host "  Trying New-VBRServerScheduleOptions..."
try {
    $S = New-VBRServerScheduleOptions -Type Daily -DailyOptions (New-VBRDailyOptions -Type Everyday -Period 1) -StartTime "22:00"
    Write-Host "  [OK] $($S.GetType().FullName)"
    $S | Get-Member -MemberType Property | ForEach-Object { $PN = $_.Name; try { Write-Host "    $PN = $($S.$PN)" } catch {} }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "  Trying New-VBRPeriodicallyOptions..."
try {
    $CMD = Get-Command New-VBRPeriodicallyOptions -ErrorAction Stop
    Write-Host "  Params:"
    $CMD.Parameters.Keys | Sort-Object | ForEach-Object {
        $P = $CMD.Parameters[$_]
        Write-Host "    $_ ($($P.ParameterType.Name))"
    }
} catch { Write-Host "  Not found" }
