## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# $installerUrl - Duo installer URL
# $installerPath - Local path and filename of Duo installer
# $transformURL - Transform file URL
# $transformPath - Local path and filename of Transform file
# $regURL - .reg file URL
# $regPath - local path and filename of reg file

# Getting input from user if not running from RMM else set variables from RMM.

# No variables are required for this script besides $Description.

$ScriptLogName = "app-duo-install.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else { 
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
        
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
        
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }     
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "InstallerURL: $installerUrl"
Write-Host "InstallerPath: $installerPath"
Write-Host "TransformURL: $transformURL"
Write-Host "TransformPath: $transformPath"
Write-Host "RegURL: $regURL"
Write-Host "RegPath: $regPath"

# Define service name
$serviceName = "DuoAuthService"

# Check if the service exists
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Host "Duo already installed. '$serviceName' service exists."
    exit 0
} else {
    Write-Host "'$serviceName' service not found. Downloading Duo installer."
    
    # Download the installer
    # Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath 
    Start-BitsTransfer -Source $installerURL -Destination $installerPath
    Start-BitsTransfer -Source $transformURL -Destination $transformPath
    Start-BitsTransfer -Source $regURL -Destination $regPath
    
    # Verify if the installer was downloaded
    if ((Test-Path $installerPath) -and ($transformPath) -and ($regPath)) {
        Write-Host "Download successful. Proceeding with installation..."
    
        # Install Duo silently
        Start-Process 'msiexec.exe' -ArgumentList @('/I', $installerPath, '/qn', '/norestart', "TRANSFORMS=$transformPath") -NoNewWindow -Wait
    
        # Check if the service exists
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    
        if ($service) {
            Write-Host "Duo installed successfully."
        } else {
            Write-Host "Duo install failed. '$serviceName' not detected."
        }

       # Apply reg file
       regedit.exe /S $regPath

       if ($LASTEXITCODE -eq 0) {
         Write-Host "Registry import was successful."
       } else {
         Write-Host "Registry import failed with exit code $LASTEXITCODE."
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
