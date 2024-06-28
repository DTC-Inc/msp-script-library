# Getting input from user if not running from RMM else set variables from RMM.
# serviceName is the only variable that needs set by the RMM. Everything else is hardcoded.

$scriptLogName = "teamviewer-uninstall.log"

if ($rmm -ne 1) {
    $validInput = 0
    # Checking for valid input.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"
        if ($description) {
            $validInput = 1
        } else {
            Write-Output "Invalid input. Please try again."
        }

        $serviceName = Read-Host "Enter the TeamViewer service name"
        if ($serviceName) {
            $validInput = 1
        } else {
            Write-Output "Invalid input. Please try again."
        }
        
    }
    $logPath = "$env:WINDIR\logs\$scriptLogName"

} else { 
    # Store the logs in the rmmScriptPath
    $logPath = "$rmmScriptPath\logs\$scriptLogName"

    if ($description -eq $null) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $description = "No description"
    }   

    Write-Output $description
    Write-Output $rmmScriptPath
    Write-Output $rmm
    
}

Start-Transcript -Path $logPath

# Check if the service exists
 $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Output "TeamViewer service found. Disabling..."

    # Stop the service if it is running
    if ($service.Status -eq "Running") {
        Stop-Service -Name $serviceName -Force
    }

    # Disable the service
    Set-Service -Name $serviceName -StartupType Disabled
    
    Write-Output "TeamViewer service has been disabled."
} else {
    Write-Output "TeamViewer service not found."
}

$test64Bit = Test-Path $ENV:PROGRAMFILES\TeamViewer\uninstall.exe -PathType Leaf
$test32Bit = Test-Path "$ENV:PROGRAMFILES (X86)\TeamViewer\uninstall.exe" -PathType Leaf
if ($test64Bit) {

    & $ENV:PROGRAMFILES\TeamViewer\uninstall.exe /S
}

if ($test32Bit) {
    & "$ENV:PROGRAMFILES (X86)\TeamViewer\uninstall.exe" /S

}



$osArchitecture = (Get-CimInstance Win32_operatingsystem).OSArchitecture

# Define the TeamViewer uninstall key
#$uninstallKey64bit = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
#$uninstallKey32bit = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"

#if ($uninstallKey64bit) {
    #$teamViewerKey = Get-ChildItem -Path $uninstallKey64bit | Where-Object { $_.GetValue("DisplayName") -like "*TeamViewer*" }
#} else { 
    #$teamViewerKey = Get-ChildItem -Path $uninstallKey32bit | Where-Object { $_.GetValue("DisplayName") -like "*TeamViewer*" }
#}

# Check if TeamViewer is installed
#if ($teamViewerKey) {
    #Write-Output "TeamViewer is installed. Uninstalling..."
    
    # Get the uninstall string
    #$uninstallString = $teamViewerKey.GetValue("UninstallString")
    
    # Remove quotes from the uninstall string if they exist
    #$uninstallString = $uninstallString -replace '"', ''
    
    # Execute the uninstall string
    #Start-Process -FilePath $uninstallString -ArgumentList "/S" -Wait
    
    #Write-Output "TeamViewer has been uninstalled."
#} else {
    #Write-Output "TeamViewer is not installed."
#}



#Stop-Transcript
