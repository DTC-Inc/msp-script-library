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

# Define the service name pattern
$ServicePattern = "*ScreenConnect*"

# Get services matching the pattern
$Services = Get-Service | Where-Object { $_.Name -like $ServicePattern }

if ($Services) {
    foreach ($Service in $Services) {
        Write-Output "Uninstalling $($Service.Name)..."
        try {
            # Uninstall the application associated with the service
            # Check if any instances are installed

            $installed = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*

            # Remove the application if it is installed

            if ($installed) {
                Write-Output "ConnectWise Control (ScreenConnect) is installed so we're uninstalling."
                $installed | ForEach-Object {
                    try {
                        $_.Uninstall()
                    } catch {
                           Write-Output "An error has occured that coult not be resolved."

                    }    
                }
            }

            # Check if application is still installed. 
            $installCheck = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*
            if ($installCheck) {
                Write-Output "Uninstall failed."
            } else {
                Write-Output "Uninstall failed for $($Service.Name). Attempting force deletion..."
                # Attempt force deletion of the service
                $Service | Stop-Service -Force -ErrorAction SilentlyContinue
                $ServiceDeleteResult = sc.exe delete "$($Service.Name)" | Write-Output
                Write-Output "Service delete output: $ServiceDeleteResult"
                # $ServiceDeleteResult | Wait-Process -Timeout 10
                $IsServiceDeleted = Get-Service | Where-Object { $_.Name -eq $Service.Name } | Select $_.Name
                Write-Output "Checking if service $($Service.Name) exists. $IsServiceDeleted"
                if (!($IsServiceDeleted)) {
                    Write-Output "Service $($Service.Name) forcibly deleted."
                    Exit 0
                } else {
                    Write-Output "Service $($Service.Name) delete failed."
                    Exit 1
                }
            }
        } catch {
            Write-Output "Error occurred while uninstalling $($Service.Name): $_"
            Exit 1
        }
    }
} else {
    Write-Output "No services found matching the pattern $ServicePattern"
    Exit 0
}

Stop-Transcript
