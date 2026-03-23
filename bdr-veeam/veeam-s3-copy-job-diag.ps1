# Diagnostic: S3 copy job - encryption setup
# Run interactively on the BDR server in PS7

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $PWSH_PATH) {
        & $PWSH_PATH -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
        exit $LASTEXITCODE
    }
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $VBD = "$env:ProgramFiles\Veeam\Backup and Replication\Backup"
    $VBR = "$VBD\runtimes\win-x64\native"
    foreach ($D in @($VBR, $VBD)) { if ((Test-Path $D) -and $env:PATH -notlike "*$D*") { $env:PATH = "$D;$env:PATH" } }
    if (Test-Path $VBD) {
        $null = [System.AppDomain]::CurrentDomain.add_AssemblyResolve({
            param($s, $a); if (-not $a.Name) { return $null }
            $N = [System.Reflection.AssemblyName]::new($a.Name)
            $F = Join-Path $VBD "$($N.Name).dll"
            if (Test-Path $F) { return [System.Reflection.Assembly]::LoadFrom($F) }; return $null
        })
    }
}

$ConfirmPreference = 'None'
$MY_MODULE_PATH = "$env:ProgramFiles\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"
Get-Module -ListAvailable -Name Veeam.Backup.PowerShell | Import-Module -WarningAction SilentlyContinue

Write-Host "=========================================="
Write-Host "1: New-VBRBackupCopyJobStorageOptions - all params + enum values"
Write-Host "=========================================="
try {
    $CMD = Get-Command New-VBRBackupCopyJobStorageOptions -ErrorAction Stop
    foreach ($KEY in ($CMD.Parameters.Keys | Sort-Object)) {
        $P = $CMD.Parameters[$KEY]
        $LINE = "  $KEY ($($P.ParameterType.Name))"
        if ($P.ParameterType.IsEnum) {
            $LINE += " = $([Enum]::GetNames($P.ParameterType) -join ', ')"
        }
        if ($P.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }) {
            $LINE += " [MANDATORY]"
        }
        Write-Host $LINE
    }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "2: Get encryption key"
Write-Host "=========================================="
$KEY = $null
try {
    $KEY = Get-VBREncryptionKey | Select-Object -First 1
    Write-Host "  Key: $($KEY.Id) - $($KEY.Description)"
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "3: Try New-VBRBackupCopyJobStorageOptions (minimal)"
Write-Host "=========================================="
try {
    Write-Host "  Trying with just -EnableEncryption -EncryptionKey..."
    $OPTS = New-VBRBackupCopyJobStorageOptions -EnableEncryption -EncryptionKey $KEY
    Write-Host "  [OK] $($OPTS.GetType().FullName)"
    $OPTS | Get-Member -MemberType Property | ForEach-Object {
        $PN = $_.Name; try { Write-Host "    $PN = $($OPTS.$PN)" } catch {}
    }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "4: Try with all params"
Write-Host "=========================================="

# Get CompressionLevel enum values
Write-Host "  CompressionLevel values:"
try {
    $T = [Veeam.Backup.PowerShell.Infos.VBRBackupCopyJobCompressionLevel]
    [Enum]::GetNames($T) | ForEach-Object { Write-Host "    $_" }
} catch { Write-Host "    Could not get enum" }

Write-Host "  StorageOptimizationType values:"
try {
    $T = [Veeam.Backup.PowerShell.Infos.VBRBackupCopyJobStorageOptimizationType]
    [Enum]::GetNames($T) | ForEach-Object { Write-Host "    $_" }
} catch { Write-Host "    Could not get enum" }

Write-Host ""
try {
    Write-Host "  Trying with all params..."
    $OPTS = New-VBRBackupCopyJobStorageOptions `
        -CompressionLevel Auto `
        -StorageOptimizationType Local `
        -EnableDataDeduplication `
        -EnableEncryption `
        -EncryptionKey $KEY
    Write-Host "  [OK]"
} catch {
    Write-Host "  FAILED: $_"
    Write-Host ""
    Write-Host "  Trying different CompressionLevel values..."
    foreach ($CL in @("Auto", "None", "Optimal", "High", "Extreme", "0", "1", "4", "5", "6", "9")) {
        try {
            $OPTS = New-VBRBackupCopyJobStorageOptions -CompressionLevel $CL -EnableEncryption -EncryptionKey $KEY
            Write-Host "    [OK] CompressionLevel=$CL"
            break
        } catch { Write-Host "    [$CL] FAILED" }
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "5: Get existing copy job and try Set-VBRBackupCopyJob"
Write-Host "=========================================="
try {
    $CJ = Get-VBRBackupCopyJob | Select-Object -First 1
    if ($CJ) {
        Write-Host "  Copy job: $($CJ.Name)"
        Write-Host "  Current StorageOptions:"
        if ($CJ.StorageOptions) {
            $CJ.StorageOptions | Get-Member -MemberType Property | ForEach-Object {
                $PN = $_.Name; try { Write-Host "    $PN = $($CJ.StorageOptions.$PN)" } catch {}
            }
        }
        Write-Host ""
        Write-Host "  Trying Set-VBRBackupCopyJob -StorageOptions..."
        if ($OPTS) {
            Set-VBRBackupCopyJob -Job $CJ -StorageOptions $OPTS
            Write-Host "  [OK] Encryption set!"
        } else {
            Write-Host "  No StorageOptions object available from previous steps."
        }
    } else {
        Write-Host "  No copy job found."
    }
} catch { Write-Host "  FAILED: $_" }

Write-Host ""
Write-Host "=========================================="
Write-Host "Done"
Write-Host "=========================================="
