# Define variables
$folderPath = "C:\VeeamInstall"  # Folder path where the file will be stored
$fileName = "VeeamBackup&Replication_12.3.0.310_20250221.iso"          # File name to check and download
$filePath = Join-Path $folderPath $fileName
$fileUrl = "https://download2.veeam.com/VBR/v12/VeeamBackup&Replication_12.3.0.310_20250221.iso"  # URL to download the file
$logFilePath = "C:\logs\veeam_download.log"  # Path for the log file

# Function to write to log file
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"
    Add-Content -Path $logFilePath -Value $logMessage
}

# Start logging
Write-Log "Script started."

# Check if the file exists
if (-Not (Test-Path $filePath)) {
    Write-Log "File not found: $filePath. Creating folder and downloading file."

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
