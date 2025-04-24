## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# $installerUrl - Teramind install URL for your instance
# $installerPath - Local path and filename of Teramind installer
# $tmRouter - Teramind TMROUTER value for your instance
# $tmInstance - Teramind TMINSTANCE value for your instance

# Getting input from user if not running from RMM else set variables from RMM.

# No variables are required for this script besides $Description.

$ScriptLogName = "app-tm-install.log"

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

# Define service name
$serviceName = "tsvchst"

# Check if the service exists
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Host "Teramind already installed. '$serviceName' service exists."
    exit 0
} else {
    Write-Host "'$serviceName' service not found. Downloading Teramind installer."
    
    # Download the installer
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath 
    
    # Verify if the installer was downloaded
    if (Test-Path $installerPath) {
        Write-Host "Download successful. Proceeding with installation..."
    
        # Install the Teramind silently
        Start-Process 'msiexec.exe' -ArgumentList @('/I', $installerPath, "TMROUTER=$tmRouter", "TMINSTANCE=$tmInstance", '/qn') -NoNewWindow -Wait
    
        # Check if the service exists
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    
        if ($service) {
            Write-Host "Teramind installed successfully."
        } else {
            Write-Host "Teramind install failed. '$serviceName' not detected."
        }
    
       # Remove the installer file
       Write-Host "Removing $installerPath"
       Remove-Item -Path $installerPath -Force
    
    } else {
        Write-Host "Download failed. Please check the URL and try again."
    }
}

Stop-Transcript
