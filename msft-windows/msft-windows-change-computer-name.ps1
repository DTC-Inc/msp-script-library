## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

$ScriptLogName = "msft-windows-rename-compuer.log"

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
