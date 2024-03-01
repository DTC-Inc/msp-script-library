# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "EnterLogNameHere.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
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

Start-Transcript -Path $LogPath

Write-Output "Description: $Description"
Write-Output "Log path: $LogPath"
Write-Output "RMM: $RMM"

Write-Output "Downloading universal automate installer."

try {
    wget $AutomateUninstaller -OutFile $ENV:WINDIR\TEMP\Agent_Uninstall.exe -ErrorAction Stop
    Write-Output "Download successful."
} catch {
    Write-Output "Error downloading: $_"
    Stop-Transcript
    Exit 3
}

Write-Output "Uninstalling automate."

try {
    & $ENV:WINDIR\TEMP\Agent_Uninstall.exe /q
    Write-Output "Uninstall successful."
} catch {
    Write-Output "Error uninstalling: $_"
    Stop-Transcript
    Exit 3
}

Stop-Transcript
Exit 0
