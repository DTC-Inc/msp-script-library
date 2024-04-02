# Getting input from user if not running from RMM else set variables from RMM.
if ($rmm -ne 1) {
    $validInput = 0
    # Only running if S3 Copy Job is true for this part.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $validInput = 1
    }
    $logPath = "$env:WINDIR\logs\hyper-v-set-team-dynamic.log"
    $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"


} else { 
    # Store the logs in the rmmScriptPath
    $logPath = "$rmmScriptPath\logs\hyper-v-set-team-dynamic.log"
    

}

Start-Transcript -Path $logPath

Write-Host "This script is being run for $description"

Get-VMSwitchTeam | Where -Property TeamingMode -eq "SwitchIndependent" | Select -Expand Name | ForEach-Object { Set-VMSwitchTeam -LoadBalancingAlgorithm Dynamic -Name $_; Write-Host "Setting VM Switch $_ to Dynamic" }


Stop-Transcript