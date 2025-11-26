# Driver Download and Installation Script for NinjaRMM
# The download URL should be provided via NinjaRMM custom field/variable
# Example NinjaRMM variable: $DriverDownloadUrl


# Validate URL is provided
if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    Write-Host "ERROR: DriverDownloadUrl variable not provided or is empty"
    Write-Host "Please set the DriverDownloadUrl custom field in NinjaRMM"
    exit 1
}

$TempPath = "$env:TEMP\DriverInstall"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    # Create temporary directory
    Write-Log "Creating temporary directory: $TempPath"
    if (Test-Path $TempPath) {
        Remove-Item $TempPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
    
    # Download the zip file
    $zipFile = Join-Path $TempPath "drivers.zip"
    Write-Log "Downloading drivers from: $DownloadUrl"
    
    # Use .NET WebClient for reliable download
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($DownloadUrl, $zipFile)
    
    Write-Log "Download completed: $zipFile"
    
    # Verify the file was downloaded
    if (!(Test-Path $zipFile)) {
        throw "Download failed - file not found at $zipFile"
    }
    
    # Extract the zip file
    $extractPath = Join-Path $TempPath "extracted"
    Write-Log "Extracting drivers to: $extractPath"
    Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
    
    # Find all .inf files in the extracted content
    Write-Log "Searching for driver .inf files..."
    $infFiles = Get-ChildItem -Path $extractPath -Filter "*.inf" -Recurse
    
    if ($infFiles.Count -eq 0) {
        throw "No .inf files found in the downloaded package"
    }
    
    Write-Log "Found $($infFiles.Count) driver package(s)"
    
    # Install each driver package to the driver store
    $successCount = 0
    $failCount = 0
    
    foreach ($inf in $infFiles) {
        Write-Log "Installing driver: $($inf.Name) from $($inf.DirectoryName)"
        
        try {
            # Use pnputil to add driver to the driver store WITHOUT requiring matching hardware
            # /add-driver adds to store, /install would require hardware match
            # Removing /install allows drivers to be staged for future hardware detection
            $result = pnputil.exe /add-driver "$($inf.FullName)" /subdirs
            
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully added to driver store: $($inf.Name)" -Level "SUCCESS"
                $successCount++
            } else {
                Write-Log "Failed to add: $($inf.Name) - Exit code: $LASTEXITCODE" -Level "WARNING"
                Write-Log "Output: $result" -Level "WARNING"
                $failCount++
            }
        }
        catch {
            Write-Log "Error installing $($inf.Name): $($_.Exception.Message)" -Level "ERROR"
            $failCount++
        }
    }
    
    # Summary
    Write-Log "============================================"
    Write-Log "Installation Summary:"
    Write-Log "  Total drivers found: $($infFiles.Count)"
    Write-Log "  Successfully installed: $successCount"
    Write-Log "  Failed: $failCount"
    Write-Log "============================================"
    
    # Cleanup
    Write-Log "Cleaning up temporary files..."
    Remove-Item $TempPath -Recurse -Force
    
    Write-Log "Driver installation process completed"
    
    if ($failCount -gt 0) {
        exit 1
    }
}
catch {
    Write-Log "Critical error: $($_.Exception.Message)" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    
    # Cleanup on error
    if (Test-Path $TempPath) {
        Remove-Item $TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    exit 1
}
