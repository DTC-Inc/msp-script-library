# PowerShell Script to Install Sysmon with SwiftOnSecurity Configuration
# This script will download Sysmon, download the SwiftOnSecurity configuration, and install Sysmon

# Set the working directory to the temp folder
$workingDir = "$env:TEMP\SysmonInstall"
New-Item -ItemType Directory -Force -Path $workingDir | Out-Null
Set-Location -Path $workingDir

Write-Host "Working directory set to: $workingDir" -ForegroundColor Green

# Define URLs
$sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
$configUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"

# Define file paths
$sysmonZip = "$workingDir\Sysmon.zip"
$configFile = "$workingDir\sysmonconfig-export.xml"

# Step 1: Download Sysmon
Write-Host "Downloading Sysmon..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $sysmonUrl -OutFile $sysmonZip
Write-Host "Downloaded Sysmon to $sysmonZip" -ForegroundColor Green

# Step 2: Extract Sysmon
Write-Host "Extracting Sysmon..." -ForegroundColor Cyan
Expand-Archive -Path $sysmonZip -DestinationPath $workingDir -Force
Write-Host "Extracted Sysmon to $workingDir" -ForegroundColor Green

# Step 3: Download SwiftOnSecurity's Sysmon config
Write-Host "Downloading SwiftOnSecurity config..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $configUrl -OutFile $configFile
Write-Host "Downloaded config to $configFile" -ForegroundColor Green

# Step 4: Install Sysmon with the config
Write-Host "Installing Sysmon with configuration..." -ForegroundColor Cyan
$sysmonExe = "$workingDir\Sysmon64.exe"
if (-not (Test-Path $sysmonExe)) {
    $sysmonExe = "$workingDir\Sysmon.exe"
}

# Check if the file exists before trying to execute
if (Test-Path $sysmonExe) {
    # Run as administrator to install Sysmon
    try {
        Start-Process -FilePath $sysmonExe -ArgumentList "-accepteula -i `"$configFile`"" -Verb RunAs -Wait
        Write-Host "Sysmon installed successfully with SwiftOnSecurity configuration!" -ForegroundColor Green
    }
    catch {
        Write-Host "Error installing Sysmon: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "Sysmon executable not found at $sysmonExe" -ForegroundColor Red
}

# Clean up (optional, comment these lines if you want to keep the files)
# Remove-Item -Path $workingDir -Recurse -Force

Write-Host "Script completed!" -ForegroundColor Green