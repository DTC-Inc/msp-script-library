
## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "recovery-partition-fix-kb5028997.log"

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

#Script to fix the recovery partition for KB5028997 by /u/InternetStranger4You 
#Mostly Powershell version of Microsoft's support article: https://support.microsoft.com/en-us/topic/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update-400faa27-9343-461c-ada9-24c8229763bf    
#Test in your own environment before running. Not responsible for any damages.

#Run reagentc.exe /info and save the output
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = "reagentc.exe"
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$pinfo.Arguments = '/info'
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $pinfo
$p.Start() | Out-Null
$p.WaitForExit()
$stdout = $p.StandardOutput.ReadToEnd()


#Disable Windows recovery environment
Start-Process "reagentc.exe" -ArgumentList "/disable" -Wait -NoNewWindow

#Verify that disk and partition are listed in reagentc.exe /info. If blank, then something is wrong with WinRE
if(($stdout.IndexOf("harddisk") -ne -1) -and ($stdout.IndexOf("partition") -ne -1)){
    #Get recovery disk number and partition number
    $DiskNum=$stdout.substring($stdout.IndexOf("harddisk")+8,1)
    $RecPartNum=$stdout.substring($stdout.IndexOf("partition")+9,1)

    #Resize OS partition
    $size=Get-Disk $DiskNum | Get-Partition -PartitionNumber ($RecPartNum-1) |Select-Object -ExpandProperty Size
    Get-Disk $DiskNum | Resize-Partition -PartitionNumber ($RecPartNum-1) -Size ($size - 250MB)
    
    #Remove the recovery partition
    Get-Disk $DiskNum | Remove-Partition -PartitionNumber $RecPartNum -Confirm:$false
    
    #Create new partion with diskpart script
    $DiskpartScriptPath = $env:TEMP
    $DiskpartScriptName = "ResizeREScript.txt"
    $DiskpartScript = $DiskpartScriptPath+'\'+$DiskpartScriptName
    "sel disk $($DiskNum)"|Out-File -FilePath $DiskpartScript -Encoding utf8 -Force
    $PartStyle = Get-Disk $DiskNum |Select-Object -ExpandProperty PartitionStyle
    if($PartStyle -eq "GPT"){
        #GPT partition commands
        "create partition primary id=de94bba4-06d1-4d40-a16a-bfd50179d6ac"|Out-File -FilePath $DiskpartScript -Encoding utf8 -Append -Force
        "gpt attributes =0x8000000000000001"|Out-File -FilePath $DiskpartScript -Encoding utf8 -Append -Force
    }else{
        #MBR partition command
        "create partition primary id=27"|Out-File -FilePath $DiskpartScript -Encoding utf8 -Append -Force
    }
    "format quick fs=ntfs label=`"Windows RE tools`""|Out-File -FilePath $DiskpartScript -Encoding utf8 -Append -Force
    Start-Process "diskpart.exe" -ArgumentList "/s $($DiskpartScriptName)" -Wait -NoNewWindow -WorkingDirectory $DiskpartScriptPath

    #Enable the recovery environment
    Start-Process "reagentc.exe" -ArgumentList "/enable" -Wait -NoNewWindow

}else{
    Write-Warning "Recovery partition not found. Aborting script."
}

Stop-Transcript
