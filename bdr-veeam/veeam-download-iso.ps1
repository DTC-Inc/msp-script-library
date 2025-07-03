# Define variables
$folderPath = "C:\VeeamInstall"  # Folder path where the file will be stored
$fileName = $savefile          # File name to check and download
$filePath = Join-Path $folderPath $fileName
$fileUrl = $downloadurl  # URL to download the file
$logFilePath = "C:\logs\veeam_download.log"  # Path for the log file
$daysThreshold = 60  # Files older than this many days will be deleted

# Function to write to log file
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Add-Content -Path $logFilePath -Value $logMessage
}

# Function to clean up old ISO files (older than specified days)
function Remove-OldIsoFiles {
    param (
        [string]$folderPath,
        [int]$daysThreshold
    )
    
    if (Test-Path $folderPath) {
        $cutoffDate = (Get-Date).AddDays(-$daysThreshold)
        $existingIsoFiles = Get-ChildItem -Path $folderPath -Filter "*.iso" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
        
        if ($existingIsoFiles.Count -gt 0) {
            Write-Log "Found $($existingIsoFiles.Count) ISO file(s) older than $daysThreshold days to remove:"
            foreach ($file in $existingIsoFiles) {
                try {
                    $fileAge = ((Get-Date) - $file.LastWriteTime).Days
                    Remove-Item -Path $file.FullName -Force
                    Write-Log "Removed old ISO file: $($file.Name) (Age: $fileAge days)"
                } catch {
                    Write-Log "Failed to remove ISO file $($file.Name): $_"
                }
            }
        } else {
            Write-Log "No ISO files older than $daysThreshold days found to remove."
        }
    }
}

# Start logging
Write-Log "Script started."

# Clean up old ISO files before proceeding
Remove-OldIsoFiles -folderPath $folderPath -daysThreshold $daysThreshold

# Check if the file exists
if (-Not (Test-Path $filePath)) {
    Write-Log "File not found: $filePath. Creating folder and downloading file. $fileUrl"
    
    # Check if the folder exists, if not, create it
    if (-Not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath | Out-Null
        Write-Log "Folder created: $folderPath"
    }
    
    # Download the file
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $fileUrl -OutFile $filePath
        Write-Log "File downloaded successfully to: $filePath"
    } catch {
        Write-Log "Failed to download the file: $_"
    }
} else {
    Write-Log "File already exists: $filePath"
}

# Finish logging
Write-Log "Script completed."
