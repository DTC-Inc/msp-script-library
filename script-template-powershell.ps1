# Getting input from user if not running from RMM else set variables from RMM.

$scriptLogName = "Put the log file name here."

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
    if ($null -eq $RMMScriptPath) {
        $logPath = "$rmmScriptPath\logs\$scriptLogName"
        
    } else {
        $logPath = "$env:WINDIR\logs\$scriptLogName"
        
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $description = "No description"
    }   


    
}

Start-Transcript -Path $logPath

Write-Host "Description: $description"
Write-Host "Log path: $logPath"
Write-Host "RMM: $rmm"

Stop-Transcript
