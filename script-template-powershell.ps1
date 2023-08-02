# Getting input from user if not running from RMM else set variables from RMM.
if ($rmm -ne 1) {
    $validInput = 0
    # Only running if S3 Copy Job is true for this part.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.

    }
    $logPath = "$env:WINDIR\logs\veeam-add-backup-repo.log"

} else { 
    # Store the logs in the rmmScriptPath
    $logPath = "$rmmScriptPath\logs\veeam-add-backup-repo.log"
    

}

Start-Transcript -Path $logPath