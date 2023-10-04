# Getting input from user if not running from RMM else set variables from RMM.

$scriptLogName = "Put the log file name here."

if ($rmm -ne 1) {
    $validInput = 0
    # Checking for valid input.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"
        $targetToDelete = Read-Host "Enter the hostname or fqdn of the credential you want to delete"
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

Write-Host "This script is being run for $description."
Write-Host "Deleting $targetToDelete."

# Clear Windows Credential Manager for the specified target
cmdkey /list | ForEach-Object {
    if ($_ -match "Target: (.+)$") {
        $target = $matches[1]
        if ($target -eq $targetToDelete) {
            Write-Host "Removing credentials for $targetToDelete"
            cmdkey /delete:$targetToDelete
        }
    }
}

Write-Host "Credentials for $targetToDelete removed from Credential Manager."


Stop-Transcript
