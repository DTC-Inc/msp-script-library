## ============================================================================================
## RMM VARIABLE DECLARATION SECTION
## ============================================================================================
## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
##
## $RMM = 1
## $mysqlRootPassword

## ============================================================================================
## INPUT HANDLING SECTION
## ============================================================================================

# Detect RMM execution context
if ($RMM -eq 1) {
    # RMM Mode - Variables should be pre-defined by RMM platform
    $LogPath = if ($RMMScriptPath) { "$RMMScriptPath\logs\" } else { "$ENV:WINDIR\logs\" }
    $Description = "MySQL All Databases Backup - RMM Execution"

    # Validate required RMM variables
    if (-not $mysqlRootPassword) {
        Write-Error "Required variable `$mysqlRootPassword not set by RMM"
        exit 1
    }
}
else {
    # Interactive Mode - Prompt user for inputs
    $LogPath = "$ENV:WINDIR\logs\"

    Write-Host "`n=== MySQL All Databases Backup Utility ===" -ForegroundColor Cyan
    Write-Host "This script will backup ALL MySQL databases and maintain 7 days of retention.`n" -ForegroundColor Yellow

    # Get MySQL root password
    $ValidInput = $false
    while (-not $ValidInput) {
        $securePassword = Read-Host "Enter MySQL root password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $mysqlRootPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if ($mysqlRootPassword) {
            $ValidInput = $true
        }
        else {
            Write-Host "Password cannot be empty. Please try again." -ForegroundColor Red
        }
    }

    $Description = "MySQL All Databases Backup - Interactive Execution"
}

# Ensure log directory exists
if (-not (Test-Path -Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$ScriptLogName = "db-mysql-backup-retention-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"

## ============================================================================================
## SCRIPT LOGIC SECTION
## ============================================================================================

Start-Transcript -Path "$LogPath\$ScriptLogName" -Append

Write-Host "`n=== MySQL All Databases Backup Script ===" -ForegroundColor Cyan
Write-Host "Description: $Description"
Write-Host "Log Path: $LogPath"
Write-Host "RMM Mode: $($RMM -eq 1)"
Write-Host "Target: All databases on localhost"
Write-Host "================================`n" -ForegroundColor Cyan

try {
    # Step 1: Find largest volume
    Write-Host "[1/6] Finding largest available volume..." -ForegroundColor Yellow
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object -Property SizeRemaining -Descending

    if (-not $volumes) {
        throw "No fixed volumes found on this system"
    }

    $largestVolume = $volumes[0]
    $backupRootPath = "$($largestVolume.DriveLetter):\mysqlbackups"

    Write-Host "    Selected volume: $($largestVolume.DriveLetter):\ (Available: $([math]::Round($largestVolume.SizeRemaining/1GB, 2)) GB)" -ForegroundColor Green

    # Step 2: Create backup directory if it doesn't exist
    Write-Host "[2/6] Ensuring backup directory exists..." -ForegroundColor Yellow
    if (-not (Test-Path -Path $backupRootPath)) {
        New-Item -ItemType Directory -Path $backupRootPath -Force | Out-Null
        Write-Host "    Created backup directory: $backupRootPath" -ForegroundColor Green
    }
    else {
        Write-Host "    Backup directory exists: $backupRootPath" -ForegroundColor Green
    }

    # Step 3: Verify mysqldump exists
    Write-Host "[3/6] Verifying mysqldump availability..." -ForegroundColor Yellow
    $mysqldumpPath = $null

    # Try to find MySQL/MariaDB installation path from registry
    $registryPaths = @(
        "HKLM:\SOFTWARE\MySQL AB",
        "HKLM:\SOFTWARE\Wow6432Node\MySQL AB",
        "HKLM:\SOFTWARE\MariaDB",
        "HKLM:\SOFTWARE\Wow6432Node\MariaDB"
    )

    foreach ($regPath in $registryPaths) {
        if (Test-Path -Path $regPath) {
            Write-Host "    Checking registry: $regPath" -ForegroundColor Gray
            $versions = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($version in $versions) {
                $installLocation = (Get-ItemProperty -Path $version.PSPath -Name "Location" -ErrorAction SilentlyContinue).Location
                if ($installLocation) {
                    $potentialPath = Join-Path -Path $installLocation -ChildPath "bin\mysqldump.exe"
                    if (Test-Path -Path $potentialPath) {
                        $mysqldumpPath = $potentialPath
                        Write-Host "    Found via registry: $mysqldumpPath" -ForegroundColor Green
                        break
                    }
                }
            }
            if ($mysqldumpPath) { break }
        }
    }

    # Fallback: Common MySQL installation paths
    if (-not $mysqldumpPath) {
        Write-Host "    Registry lookup failed, checking common paths..." -ForegroundColor Gray
        $commonPaths = @(
            "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe",
            "C:\Program Files\MySQL\MySQL Server 9.0\bin\mysqldump.exe",
            "C:\Program Files\MySQL\MySQL Server 5.7\bin\mysqldump.exe",
            "C:\Program Files (x86)\MySQL\MySQL Server 8.0\bin\mysqldump.exe",
            "C:\Program Files (x86)\MySQL\MySQL Server 5.7\bin\mysqldump.exe",
            "C:\Program Files\MariaDB 10.6\bin\mysqldump.exe",
            "C:\Program Files\MariaDB 10.5\bin\mysqldump.exe",
            "C:\Program Files\MariaDB 11.0\bin\mysqldump.exe",
            "C:\xampp\mysql\bin\mysqldump.exe",
            "C:\wamp64\bin\mysql\mysql8.0.27\bin\mysqldump.exe"
        )

        foreach ($path in $commonPaths) {
            if (Test-Path -Path $path) {
                $mysqldumpPath = $path
                Write-Host "    Found at common path: $mysqldumpPath" -ForegroundColor Green
                break
            }
        }
    }

    # Try to find mysqldump in PATH
    if (-not $mysqldumpPath) {
        Write-Host "    Checking system PATH..." -ForegroundColor Gray
        try {
            $mysqldumpPath = (Get-Command mysqldump -ErrorAction Stop).Source
            Write-Host "    Found in PATH: $mysqldumpPath" -ForegroundColor Green
        }
        catch {
            # Not in PATH
        }
    }

    if (-not $mysqldumpPath) {
        throw "mysqldump.exe not found. Please ensure MySQL or MariaDB is installed or add mysqldump to PATH."
    }

    Write-Host "    Using: $mysqldumpPath" -ForegroundColor Cyan

    # Step 4: Create timestamped backup
    Write-Host "[4/6] Creating all databases backup..." -ForegroundColor Yellow
    $timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
    $backupFileName = "all-databases_$timestamp.sql"
    $backupFilePath = Join-Path -Path $backupRootPath -ChildPath $backupFileName

    Write-Host "    Backup file: $backupFileName" -ForegroundColor Cyan

    # Build mysqldump command
    $mysqldumpArgs = @(
        "--user=root",
        "--password=$mysqlRootPassword",
        "--all-databases",
        "--single-transaction",
        "--quick",
        "--lock-tables=false",
        "--result-file=`"$backupFilePath`""
    )

    $process = Start-Process -FilePath $mysqldumpPath -ArgumentList $mysqldumpArgs -NoNewWindow -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw "mysqldump failed with exit code: $($process.ExitCode)"
    }

    if (-not (Test-Path -Path $backupFilePath)) {
        throw "Backup file was not created: $backupFilePath"
    }

    $backupSizeMB = [math]::Round((Get-Item $backupFilePath).Length / 1MB, 2)
    Write-Host "    Backup created successfully ($backupSizeMB MB)" -ForegroundColor Green

    # Step 5: Compress backup to ZIP
    Write-Host "[5/6] Compressing backup..." -ForegroundColor Yellow
    $zipFileName = "all-databases_$timestamp.zip"
    $zipFilePath = Join-Path -Path $backupRootPath -ChildPath $zipFileName

    Compress-Archive -Path $backupFilePath -DestinationPath $zipFilePath -CompressionLevel Optimal -Force

    if (-not (Test-Path -Path $zipFilePath)) {
        throw "ZIP file was not created: $zipFilePath"
    }

    $zipSizeMB = [math]::Round((Get-Item $zipFilePath).Length / 1MB, 2)
    Write-Host "    Compressed to: $zipFileName ($zipSizeMB MB)" -ForegroundColor Green

    # Remove uncompressed SQL file
    Remove-Item -Path $backupFilePath -Force
    Write-Host "    Removed uncompressed SQL file" -ForegroundColor Green

    # Step 6: Cleanup old backups (keep only 7 most recent)
    Write-Host "[6/6] Cleaning up old backups..." -ForegroundColor Yellow
    $existingBackups = Get-ChildItem -Path $backupRootPath -Filter "all-databases_*.zip" | Sort-Object -Property LastWriteTime -Descending

    $backupsToKeep = 7
    $backupsToDelete = $existingBackups | Select-Object -Skip $backupsToKeep

    if ($backupsToDelete) {
        foreach ($backup in $backupsToDelete) {
            Remove-Item -Path $backup.FullName -Force
            Write-Host "    Deleted old backup: $($backup.Name)" -ForegroundColor Gray
        }
        Write-Host "    Removed $($backupsToDelete.Count) old backup(s)" -ForegroundColor Green
    }
    else {
        Write-Host "    No old backups to remove (total backups: $($existingBackups.Count))" -ForegroundColor Green
    }

    Write-Host "`n=== Backup Completed Successfully ===" -ForegroundColor Green
    Write-Host "Backup Location: $zipFilePath" -ForegroundColor Cyan
    Write-Host "Total Backups Retained: $([Math]::Min($existingBackups.Count, $backupsToKeep))" -ForegroundColor Cyan

    exit 0
}
catch {
    Write-Host "`n=== ERROR ===" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript
}
