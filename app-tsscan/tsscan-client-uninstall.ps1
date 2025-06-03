## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "tsscan-client-uninstall.log"

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

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# Uninstall-TSScanClient.ps1
$paths = @(
  "${env:ProgramFiles(x86)}\TerminalWorks\TSScan Client\unins000.exe",
  "${env:ProgramFiles}\TerminalWorks\TSScan Client\unins000.exe",
  "${env:ProgramFiles(x86)}\TerminalWorks\TSScan\unins000.exe",
  "${env:ProgramFiles}\TerminalWorks\TSScan\unins000.exe"
)

$unins = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $unins) {
  $unins = Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* ,
                             HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
          Where-Object { $_.DisplayName -like 'TSScan Client*' } |
          Select-Object -ExpandProperty UninstallString -First 1
}

if ($unins) { Start-Process $unins '/SILENT' -Wait }
else        { Write-Warning 'TSScan Client not found.' }


Stop-Transcript
