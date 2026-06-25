## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $WorkstationRebootDay / $env:WorkstationRebootDay needs declared in RMM, else defaults to Everyday
## $ServerRebootDay / $env:ServerRebootDay needs declared in RMM, else defaults to Saturday
## $HypervisorRebootDay / $env:HypervisorRebootDay needs declared in RMM, else defaults to Tuesday
## $RebootHourStart / $env:RebootHourStart needs declared in RMM, else defaults to 3 AM
## $RebootStaggerMax / $env:RebootStaggerMax, needs declared in RMM, else defaults to 5400
## $RebootThreshold / $env:RebootThreshold needs declared in RMM ,else defaults to 50
## $RebootCount / $env:RebootCount must be available, not declared. This scripts adds to this counter until it hits 1 less than the RebootThreshold.
## $Description / $env:Description - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# No variables are required for this script besides $Description.

# This script should be scheduled or run on-demand to prevent a mistake reboot.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description          = $env:Description,
    [string]$RMMScriptPath        = $env:RMMScriptPath,
    [string]$WorkstationRebootDay = $env:WorkstationRebootDay,
    [string]$ServerRebootDay      = $env:ServerRebootDay,
    [string]$HypervisorRebootDay  = $env:HypervisorRebootDay,
    [string]$RebootHourStart      = $env:RebootHourStart,
    [string]$RebootStaggerMax     = $env:RebootStaggerMax,
    [string]$RebootThreshold      = $env:RebootThreshold,
    [string]$RebootCount          = $env:RebootCount
)

$ScriptLogName = "msft-windows-reboot-maintenance-window.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ($null -eq $Description -or $Description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "Workstation Reboot Day: $WorkstationRebootDay"
Write-Host "Server Reboot Day: $ServerRebootDay"
Write-Host "Hypervisor Reboot Day: $HypervisorRebootDay"
Write-Host "Reboot Hour Start: $RebootHourStart"
Write-Host "Reboot Stagger Max: $RebootStaggerMax"
Write-Host "Reboot Threshold: $RebootThreshold"
Write-Host "Reboot Count: $RebootCount"

# Get OS information
$OsInfo = Get-WmiObject -Class Win32_OperatingSystem

# Check the OS type
if ($OsInfo.Caption -match "Windows Server") {
$ServerRole = (Get-WindowsFeature -Name Hyper-V).Installed
    if ($ServerRole) {
        Write-Output "This endpoint is a Hyper-V host (Windows Server with Hyper-V role)."
        $RebootDay = $HypervisorRebootDay
        if ($RebootDay -eq $null) {
            $RebootDay = "Tuesday"
        }
    } else {
        Write-Output "This endpoint is a regular Windows Server."
        $RebootDay = $ServerRebootDay
        if ($RebootDay -eq $null) {
            $RebootDay = "Saturday"
        }
    }
} elseif ($OsInfo.Caption -match "Windows 10|Windows 11") {
    Write-Output "This endpoint is a workstation."
    $RebootDay = $WorkstationRebootDay
    if ($RebootDay -eq $null){
        $RebootDay = "Everyday"
    }
} else {
    Write-Output "This endpoint type is unknown or unsupported."
    Exit 0
}

if ($RebootDay -eq "Manual") {
    Write-Host "Reboots are done manually for this endpoint. Exiting."
    Exit 0
}

if ($RebootDay -eq $null) {
    $RebootDay = "Everyday"
    Write-Host "Reboot Day is null so we are setting the default to $RebootDay."
}

if ($RebootHourStart -eq $null) {
    $RebootHourStart = 3
    Write-Host "Reboot Hour Start is null so we are setting the default to $RebootHourStart."
}

if ($RebootStaggerMax -eq $null) {
    $RebootStaggerMax = 3600
    Write-Host "Reboot Stagger Max is null sow we are setting the default to $RebootStaggerMax."
}

if ($RebootThreshold -eq $null) {
    $RebootThreshold = 50
    Write-Host "Reboot threshold was null, setting this to 50."
}

if ($RebootCount -eq $null) {
    $RebootCount = 0
    Write-Host "Reboot count was null, setting this to 0."
}

Write-Host "The reboot day for this endpoint is $RebootDay"

# Define the target time (e.g., 3 AM next day)
$TargetTime = (Get-Date).Date.AddHours($RebootHourStart)

# Get the current time
$Now = Get-Date

# Calculate the time difference
$TimeDifference = $TargetTime - $Now

# If the target time has already passed today, set the target time to 3 AM tomorrow
if ($TimeDifference.TotalSeconds -lt 0) {
    $TargetTime = (Get-Date).AddDays(1).Date.AddHours($RebootHourStart)
    $TimeDifference = $TargetTime - $Now
}

# Output the time difference for logging
Write-Host "Time difference: $($TimeDifference.Hours) hours, $($TimeDifference.Minutes) minutes."

if ($now.DayOfWeek -eq '$RebootDay') {
    if ($RebootCount -le $RebootThreshold) {
        Write-Host "We're under the $RebootThreshold with reboot count $RebootCount. Rebooting the computer..."

        # Get random time to hold the reboot
        $RandomSleep = Get-Random -Minimum 60 -Maximum $RebootStaggerMax
       
        # Calculate Time Difference with Random Sleep
        $RebootHoldTime = $($TimeDifference.TotalSeconds) + $RandomSleep

        # Sleep for the reboot hold time
        Write-Host "Holding reboot for $RebootHoldTime seconds."
        Start-Sleep -Seconds $RebootHoldTime

        # Restart the endpoint
        Restart-Computer -Force

        ## DISABLED LEGACY LOGIC $ShutdownPath = $ENV:WINDIR + "\System32\shutdown.exe"  
        ## DISABLED LEGACY LOGIC & $ShutdownPath -r -t $RandomSleep -f -c "Your MSP is rebooting this endpoint for pending maintenance in $($RandomSleep/60) minutes. Reboot time range script."

        # Disabled until RMM supports cross organization Reboot Count field $RebootCount = $RebootCount + 1
    } else {
        Write-Host "Reboot threshold has been meant. Not rebooting. Reboot Count: $RebootCount. Reboot Threshold: $RebootThreshold."
    }

} elseif ($RebootDay -eq "Everyday") {
    if ($RebootCount -le $RebootThreshold) {
        Write-Host "We're under the $RebootThreshold with reboot count $RebootCount. Rebooting the computer..."

        # Get random time to hold the reboot
        $RandomSleep = Get-Random -Minimum 60 -Maximum $RebootStaggerMax
       
        # Calculate Time Difference with Random Sleep
        $RebootHoldTime = $($TimeDifference.TotalSeconds) + $RandomSleep

        # Sleep for the reboot hold time
        Write-Host "Holding reboot for $RebootHoldTime seconds."
        Start-Sleep -Seconds $RebootHoldTime

        # Restart the endpoint
        Restart-Computer -Force

        ## DISABLED LEGACY LOGIC $ShutdownPath = $ENV:WINDIR + "\System32\shutdown.exe"  
        ## DISABLED LEGACY LOGIC & $ShutdownPath -r -t $RandomSleep -f -c "Your MSP is rebooting this endpoint for pending maintenance in $($RandomSleep/60) minutes. Reboot time range script."

        # Disabled until RMM supports cross organization Reboot Count field $RebootCount = $RebootCount + 1
    } else {
        Write-Host "Reboot threshold has been meant. Not rebooting. Reboot Count: $RebootCount. Reboot Threshold: $RebootThreshold."
    }

} else {
    Write-Host "It is not $RebootHourStart on a $RebootDay. Not rebooting."

}

Stop-Transcript
