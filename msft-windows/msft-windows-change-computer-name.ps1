## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
# $NewComputerName
# $RenameNeeded (set to true in RMM if rename needed)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-rename-compuer.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information. Computer name pulled from environmental variable
        # Remember to make ValidInput = 1 whenever correct input is given.
        
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
        
        $CurrentComputerName = $env:COMPUTERNAME
        
        $NewComputerName = Read-Host "Enter the new computer name. Must be 15 characters or less and only contain letters, numbers and hyphens."
        if (($NewComputerName.Length -le 15 -and $NewComputerName -match '^[a-zA-Z0-9-]+$')) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
        
        $userInput = Read-Host "Please enter 'True' to rename computer or 'False' to keep existing name"
        # Convert the input to a boolean
        try {
            $RenameNeeded = [bool]::Parse($userInput)
            Write-Host "You entered a valid Boolean value: $RenameNeeded"
            $ValidInput = 1
        } catch {
            Write-Host "Invalid input. Please enter 'True' or 'False'."
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
Write-Host "RMM: $RMM `n"

# Rename computer if needed

If ($RenameNeeded) {
   # Rename the computer
   try {
       Rename-Computer -NewName $NewComputerName -Force
       Write-Host "Computer name has been changed to $NewComputerName and will take effect on next reboot"
   } catch {
       Write-Host "Failed to rename the computer. Error: $_"
   }
} else {
  # Rename not needed
  Write-Host "Computer rename not needed. No action taken."
}

Stop-Transcript
