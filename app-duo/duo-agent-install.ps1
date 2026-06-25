## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.

# $Description / $env:Description - Ticket # or initials for audit trail (default: "No Description")
# $installerUrl / $env:installerUrl - Duo installer URL
# $installerPath / $env:installerPath - Local path and filename of Duo installer
# $transformURL / $env:transformURL - Transform file URL
# $transformPath / $env:transformPath - Local path and filename of Transform file
# $regURL / $env:regURL - Reg file URL
# $regPath / $env:regPath - local path and filename of reg file
# $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# No variables are required for this script besides $Description.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$installerUrl  = $env:installerUrl,
    [string]$installerPath = $env:installerPath,
    [string]$transformURL  = $env:transformURL,
    [string]$transformPath = $env:transformPath,
    [string]$regURL        = $env:regURL,
    [string]$regPath       = $env:regPath,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "app-duo-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "InstallerURL: $installerUrl"
Write-Host "InstallerPath: $installerPath"
Write-Host "TransformURL: $transformURL"
Write-Host "TransformPath: $transformPath"
Write-Host "RegURL: $regURL"
Write-Host "RegPath: $regPath"

# Define variable to check for Duo install
$programName = "Duo Authentication for Windows Logon x64"

# Check if Duo installed

$installed = Get-WmiObject -Class Win32_Product | Where-Object {
    $_.Name -like "*$programName*"
}

if ($installed) {
    Write-Host "$programName is already installed."
    exit 0
} else {
    Write-Host "$programName not found. Downloading Duo installer."
    
    # Download the installer
    Start-BitsTransfer -Source $installerURL -Destination $installerPath
    Start-BitsTransfer -Source $transformURL -Destination $transformPath
    Start-BitsTransfer -Source $regURL -Destination $regPath
    
    # Verify if the installer was downloaded
    if ((Test-Path $installerPath) -and ($transformPath) -and ($regPath)) {
        Write-Host "Download successful. Proceeding with installation..."
    
        # Install Duo silently
        Start-Process 'msiexec.exe' -ArgumentList @('/I', $installerPath, '/qn', '/norestart', "TRANSFORMS=$transformPath") -NoNewWindow -Wait
    
        # Check if Duo installed
        $installed = Get-WmiObject -Class Win32_Product | Where-Object {
            $_.Name -like "*$programName*"
        }
        
        if ($installed) {
            Write-Host "Duo installed successfully."
            
            # Apply reg file
            regedit.exe /S $regPath

            if ($LASTEXITCODE -eq 0) {
              Write-Host "Registry import was successful."
            } else {
              Write-Host "Registry import failed with exit code $LASTEXITCODE."
            }
            
        } else {
            Write-Host "Duo install failed. '$programName' not detected."
        }
         
       # Remove the installer file
       Write-Host "Removing $installerPath"
       Remove-Item -Path $installerPath -Force
       Write-Host "Removing $transformPath"
       Remove-Item -Path $transformPath -Force
       Write-Host "Removing $regPath"
       Remove-Item -Path $regPath -Force
    
    } else {
        Write-Host "Download failed. Please check the URL and try again."
    }
}

Stop-Transcript
