# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "restart-eaglesoft.log"

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

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# Define the registry path to check
$registryPath = "HKLM:\SOFTWARE\WOW6432Node\Eaglesoft\Paths"
$valueName = "Shared Files"

# Check if the registry path exists
if (Test-Path $registryPath) {
    # Retrieve the value stored at the specified registry path
    $value = Get-ItemProperty -Path $registryPath | Select-Object -ExpandProperty $valueName

    if ($value) {
        # If the value exists, launch the executable using the retrieved value
        $executablePath = $value
        # Check if the executable file exists
        if (Test-Path $executablePath) {
            # Launch the executable
            & $executablePath\PattersonServerStatus.exe -stop
            Start-Sleep 600
            & $executablePath\PattersonServerStatus.exe -start
        } else {
            Write-Host "Executable file not found at path: $executablePath"
        }
    } else {
        Write-Host "Value '$valueName' not found at registry path: $registryPath"
    }
} else {
    Write-Host "Registry path does not exist: $registryPath"
}

Stop-Transcript
