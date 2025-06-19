# Define variables
$folderPath = "C:\VeeamInstall"  # Folder path where the file will be stored
$fileName = $savefile          # File name to check and download
$filePath = Join-Path $folderPath $fileName
$fileUrl = $downloadurl  # URL to download the file
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

# Function to clean up existing ISO files (except the target file)
function Remove-ExistingIsoFiles {
    param (
        [string]$folderPath,
        [string]$targetFileName
    )
    
    if (Test-Path $folderPath) {
        $existingIsoFiles = Get-ChildItem -Path $folderPath -Filter "*.iso" | Where-Object { $_.Name -ne $targetFileName }
        
        if ($existingIsoFiles.Count -gt 0) {
            Write-Log "Found $($existingIsoFiles.Count) existing ISO file(s) to remove:"
            foreach ($file in $existingIsoFiles) {
                try {
                    Remove-Item -Path $file.FullName -Force
                    Write-Log "Removed existing ISO file: $($file.Name)"
                } catch {
                    Write-Log "Failed to remove ISO file $($file.Name): $_"
                }
            }
        } else {
            Write-Log "No existing ISO files found to remove."
        }
    }
}

# Start logging
Write-Log "Script started."

# Clean up existing ISO files before proceeding
Remove-ExistingIsoFiles -folderPath $folderPath -targetFileName $fileName

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
