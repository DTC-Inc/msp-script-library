## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## No additional variables required for this script

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "google-drive-install.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# Script Logic

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

$packageId = "Google.GoogleDrive"
$installerUrl = "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe"
$installerPath = "$env:WINDIR\temp\GoogleDriveSetup.exe"

# Check if Google Drive is already installed
$driveExePath = "C:\Program Files\Google\Drive File Stream\launch.bat"
$driveExePath2 = "${env:ProgramFiles}\Google\Drive File Stream\GoogleDriveFS.exe"

if ((Test-Path -Path $driveExePath) -or (Test-Path -Path $driveExePath2)) {
    Write-Host "Google Drive is already installed. Skipping installation."
    Stop-Transcript
    exit 0
}

# Try winget first
$wingetAvailable = $false
try {
    $wingetCheck = winget --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        $wingetAvailable = $true
        Write-Host "Winget detected: $wingetCheck"
    }
} catch {
    Write-Host "Winget not available."
}

if ($wingetAvailable) {
    Write-Host "Installing Google Drive via winget..."
    winget install -e --id $packageId --silent --accept-package-agreements --accept-source-agreements

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Google Drive has been successfully installed via winget."
        Stop-Transcript
        exit 0
    } else {
        Write-Host "Winget install failed (exit code: $LASTEXITCODE). Falling back to direct download."
    }
}

# Fallback: direct download from Google
Write-Host "Downloading Google Drive installer from $installerUrl..."
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
} catch {
    Write-Host "Failed to download Google Drive installer: $_"
    Stop-Transcript
    exit 1
}

if (-not (Test-Path -Path $installerPath)) {
    Write-Host "Installer not found at $installerPath. Download may have failed."
    Stop-Transcript
    exit 1
}

Write-Host "Running Google Drive installer silently..."
Start-Process -FilePath $installerPath -ArgumentList "--silent --desktop_shortcut" -Wait -NoNewWindow

if ($LASTEXITCODE -eq 0) {
    Write-Host "Google Drive has been successfully installed via direct download."
} else {
    Write-Host "Google Drive installer returned exit code: $LASTEXITCODE"
}

# Cleanup installer
if (Test-Path -Path $installerPath) {
    Remove-Item -Path $installerPath -Force
    Write-Host "Cleaned up installer file."
}

Stop-Transcript
