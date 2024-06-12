## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
#
# $copilotButtonRegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
# $copilotRegPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
# $recallRegPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "disable-copilot-and-recall.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $copilotButtonRegPath = Read-Host "Enter the reg path to the Copilot button/taskbar icon withhout quotes"
        $copilotRegPath = Read-Host "Enter the reg path for Copilot without quotes"
        $recallRegPath = Read-Host "Enter the reg path for Recall without quotes"
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

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Copilot Button Reg Path: $copilotButtonRegPath"
Write-Host "Copilot Reg Path: $copilotRegPath"
Write-Host "Recall Reg Path: $recallRegPath"

# This script turns off Microsoft Copilot, hides the Copilot taskbar icon and disables Recall

# Variables need set in RMM
# $copilotButtonRegPath, $copilotRegPath, $recallRegPath

# Turn off Copilot
if (!(Test-Path $copilotRegPath)) {
     New-Item -Path $copilotRegPath
     Write-Host "Registry key created - $copilotRegPath"
}
Set-ItemProperty -Path $copilotRegPath -Name "TurnOffWindowsCopilot" -Value 1
Write-Host "TurnOffWindowsCopilot reg value set to 1"

# Hide Copilot taskbar icon
Set-ItemProperty -Path $copilotButtonRegPath -Name "ShowCopilotButton" -Value 0
Write-Host "ShowCopilotButton reg value set to 0"

# Disable Recall
if (!(Test-Path $recallRegPath)) {
     New-Item -Path $recallRegPath
     Write-Host "Registry key created - $recallRegPath"
}
Set-ItemProperty -Path $recallRegPath -Name "DisableAIDataAnalysis" -Value 1
Write-Host "DisableAIDataAnalysis reg value set to 1"

Stop-Transcript
