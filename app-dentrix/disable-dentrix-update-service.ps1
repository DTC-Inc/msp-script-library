# Getting input from user if not running from RMM else set variables from RMM.

$scriptLogName = "disable-dentrix-update-service.log"

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
    
}

Start-Transcript -Path $logPath
    Write-Host "Description: $description"
    Write-Host "Log path: $logPath"
    Write-Host "RMM: $rmm"
    
    # Specify the name of the service you want to disable
    $serviceName = "DtxUpdaterSrv"

    # Check if the service exists
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        # Stop the service if it's running
        if (Get-Service -Name $serviceName | Where-Object { $_.Status -eq 'Running' }) {
            Stop-Service -Name $serviceName
            Write-Host "Service '$serviceName' stopped successfully."
        }

        # Disable the service
        Set-Service -Name $serviceName -StartupType Disabled
        Write-Host "Service '$serviceName' disabled successfully."
    } else {
        # Exit if the service doesn't exist
        Write-Host "Service '$serviceName' not found. Exiting script."
        exit
    }

Stop-Transcript
