# Getting input from user if not running from RMM else set variables from RMM.

$scriptLogName = "cw-control-uninstall.log"

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
            Write-Host "Invalid input. Please try again."
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

    Write-Host $description
    Write-Host $rmmScriptPath
    Write-Host $rmm
    
}

Start-Transcript -Path $logPath

Write-Host "This script is being run for $description"

# Check if any instances are installed

$installed = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*

# Remove the application if it is installed

if ($installed) {
    Write-Host "ConnectWise Control (ScreenConnect) is installed so we're uninstalling."
    try {
        $installed.Uninstall()
    }
    catch {
            Write-Host "An error has occured that coult not be resolved."

    }    
}

# Check if application is still installed. 

$installCheck = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*

if ($installCheck) {
    Write-Host "Uninstall failed."
}

Stop-Transcript