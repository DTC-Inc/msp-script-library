# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "windows-hyper-v-checkpoint-aging.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $DaysAging = Read-Host "Please enter the amount of days to consider a Hyper-V"
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
        Write-Output "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }   


    
}

Start-Transcript -Path $LogPath

Write-Output "Description: $Description"
Write-Output "Log path: $LogPath"
Write-Output "RMM: $RMM"
Write-Output "Days Aging: $DaysAging"

if (-not (Get-WindowsFeature -Name Hyper-V)) {
    Exit 0
}

$AgingCheckpoints = Get-VM | Get-VMSnapshot | Where {$_.CreationTime -lt (Get-Date).AddDays($DaysAging)}

if ($AgingCheckpoints) { 
    $AgingCheckpoints | ForEach-Object { Write-Output "Checkpoint $($_.Name) is older than 1 day. Please delete this checkpoint."}
    Exit 1
} else {
    Write-Output "There are no checkpoints older than 1 day that need to be deleted."
    Exit 0
}

Stop-Transcript
