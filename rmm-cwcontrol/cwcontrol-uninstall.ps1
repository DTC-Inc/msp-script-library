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

# Define the service name pattern
$ServicePattern = "*ScreenConnect*"

# Get services matching the pattern
$Services = Get-Service | Where-Object { $_.Name -like $ServicePattern }

if ($Services) {
    foreach ($Service in $Services) {
        Write-Host "Uninstalling $($Service.Name)..."
        try {
            # Uninstall the application associated with the service
            $UninstallResult = Start-Process "msiexec.exe" -ArgumentList "/x $($Service.Name)" -PassThru -ErrorAction Stop
            $UninstallResult | Wait-Process -Timeout 30
            if ($UninstallResult.ExitCode -eq 0) {
                Write-Host "Uninstall successful for $($Service.Name)"
            } else {
                Write-Host "Uninstall failed for $($Service.Name). Attempting force deletion..."
                # Attempt force deletion of the service
                $Service | Stop-Service -Force -ErrorAction SilentlyContinue
                $ServiceDeleteResult = sc.exe delete "$Service.Name"
                # $ServiceDeleteResult | Wait-Process -Timeout 10
                $IsServiceDeleted = Get-Service | Where-Object { $_.Name -like $Service.Name
                if (!($IsServiceDeleted)) {                    
                    Write-Host "Service $($Service.Name) forcibly deleted."
                    Exit 0
                } else {
                    Write-Output "Service $($Service.Name) delete failed."
                    Exit 1
                }
            }
        } catch {
            Write-Host "Error occurred while uninstalling $($Service.Name): $_"
            Exit 1
        }
    }
} else {
    Write-Host "No services found matching the pattern $ServicePattern"
    Exit 0
}

Stop-Transcript
