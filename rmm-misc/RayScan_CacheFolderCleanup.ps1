# Script to delete files and folders older than 15 days from specified locations
# Purpose: Medical imaging cleanup script for Ray scanning system

# Define log file path
$logFile = "C:\Windows\Logs\RayScanCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Function to write to log file
function Write-Log {
    param(
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

# Start logging
Write-Log "Starting cleanup operation for files and folders older than 15 days"

# Define the paths to clean up
$pathsToClean = @(
    "C:\Ray\RayScanN\DCM\CT",
    "C:\Ray\RayScanN\DCM\PX",
    "C:\Ray\RayScanN\RCN\CT",
    "C:\Ray\RayScanN\RCN\PX",
    "C:\Ray\RayScanN\SCAN\CT",
    "C:\Ray\RayScanN\SCAN\PX"
)

# Get the cutoff date (15 days ago)
$cutoffDate = (Get-Date).AddDays(-15)

# Initialize counters
$deletedFilesCount = 0
$deletedFoldersCount = 0
$deletedLogFilesCount = 0
$errorCount = 0

# Process each path
foreach ($path in $pathsToClean) {
    Write-Log "Processing path: $path"
    
    # Check if the path exists
    if (-not (Test-Path -Path $path)) {
        Write-Log "Path does not exist: $path"
        continue
    }
    
    try {
        # Delete files older than 15 days
        Get-ChildItem -Path $path -File -Recurse | Where-Object { $_.LastWriteTime -lt $cutoffDate } | ForEach-Object {
            try {
                $filePath = $_.FullName
                Remove-Item -Path $filePath -Force
                Write-Log "Deleted file: $filePath"
                $deletedFilesCount++
            }
            catch {
                Write-Log "Error deleting file $($_.FullName): $($_.Exception.Message)"
                $errorCount++
            }
        }
        
        # Delete empty folders regardless of age (bottom-up approach to ensure child folders are processed first)
        Get-ChildItem -Path $path -Directory -Recurse | Sort-Object -Property FullName -Descending | Where-Object { 
            (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 
        } | ForEach-Object {
            try {
                $folderPath = $_.FullName
                Remove-Item -Path $folderPath -Force -Recurse
                Write-Log "Deleted empty folder: $folderPath"
                $deletedFoldersCount++
            }
            catch {
                Write-Log "Error deleting folder $($_.FullName): $($_.Exception.Message)"
                $errorCount++
            }
        }
    }
    catch {
        Write-Log "Error processing path ${path}: $($_.Exception.Message)"
        $errorCount++
    }
}

# Clean up old log files (over 7 days)
Write-Log "Starting cleanup of old log files (over 7 days old)"
$logCutoffDate = (Get-Date).AddDays(-7)
$logPath = "C:\Windows\Logs"

# Only target RayScan log files
$logFilePattern = "RayScanCleanup_*.txt"

if (Test-Path -Path $logPath) {
    try {
        # Find and delete old log files
        Get-ChildItem -Path $logPath -File -Filter $logFilePattern | Where-Object { $_.LastWriteTime -lt $logCutoffDate } | ForEach-Object {
            try {
                $oldLogFile = $_.FullName
                Remove-Item -Path $oldLogFile -Force
                Write-Log "Deleted old log file: $oldLogFile"
                $deletedLogFilesCount++
            }
            catch {
                Write-Log "Error deleting log file $($_.FullName): $($_.Exception.Message)"
                $errorCount++
            }
        }
    }
    catch {
        Write-Log "Error processing log directory ${logPath}: $($_.Exception.Message)"
        $errorCount++
    }
}
else {
    Write-Log "Log directory not found: $logPath"
}

# Write summary to log
Write-Log "Cleanup operation completed."
Write-Log "Total files deleted: $deletedFilesCount"
Write-Log "Total folders deleted: $deletedFoldersCount"
Write-Log "Total log files deleted: $deletedLogFilesCount"
Write-Log "Total errors encountered: $errorCount"

# Output summary to console
Write-Host "Cleanup operation completed."
Write-Host "Total files deleted: $deletedFilesCount"
Write-Host "Total folders deleted: $deletedFoldersCount"
Write-Host "Total log files deleted: $deletedLogFilesCount"
Write-Host "Total errors encountered: $errorCount"
Write-Host "See log file for details: $logFile"