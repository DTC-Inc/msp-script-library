## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $env:RMM         - Set to "1" when running from the RMM. Anything else is treated as interactive.
## $env:Description - Ticket # and/or technician initials. Used as the job Description for audit trail.
## $env:DaysAging   - Number of days old a checkpoint must be to flag it. Negative or positive both work
##                    (e.g. "-7" or "7" both mean "older than 7 days").

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "windows-hyper-v-checkpoint-aging.log"

# NinjaRMM passes preset variables as environment variables. Older deployments of this
# script injected them as bare PowerShell variables. Coalesce bare -> env so the script
# works regardless of how the RMM supplies them, then reference $env: consistently below.
if ([string]::IsNullOrEmpty($env:RMM)         -and $RMM)         { $env:RMM = $RMM }
if ([string]::IsNullOrEmpty($env:Description) -and $Description) { $env:Description = $Description }
if ([string]::IsNullOrEmpty($env:DaysAging)   -and $DaysAging)   { $env:DaysAging = $DaysAging }

if ($env:RMM -ne "1") {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $env:Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $env:DaysAging = Read-Host "Please enter the number of days old a Hyper-V checkpoint must be to flag it (e.g. 7)"
        if ($env:Description -and ($env:DaysAging -as [int])) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath if available, otherwise fall back to the Windows logs dir.
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Output "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

# Normalize DaysAging to a negative integer so AddDays() walks backwards from now.
# Accepts "7", "-7", or empty (defaults to 1 day).
$daysAgingInt = $env:DaysAging -as [int]
if ($null -eq $daysAgingInt) { $daysAgingInt = 1 }
$daysAgingInt = -[math]::Abs($daysAgingInt)

Start-Transcript -Path $LogPath

Write-Output "Description: $env:Description"
Write-Output "Log path: $LogPath"
Write-Output "RMM: $env:RMM"
Write-Output "Days Aging: $daysAgingInt"

# Detect Hyper-V WITHOUT the ServerManager module / Get-WindowsFeature.
#
# Get-WindowsFeature lives in the ServerManager module, which is Server-only and is NOT
# supported in the 32-bit PowerShell host that NinjaRMM uses to run scripts -- calling it
# there throws "Thread failed to start" (System.Threading.ThreadStartException).
#
# The Hyper-V Virtual Machine Management service (vmms) and the Get-VM cmdlet are present
# only when the Hyper-V platform is installed, and both are bitness-safe on client + server.
$vmmsService = Get-Service -Name "vmms" -ErrorAction SilentlyContinue
if (-not $vmmsService) {
    Write-Output "Hyper-V is not installed on this machine (vmms service not found)."
    Stop-Transcript
    Exit 0
}

if (-not (Get-Command -Name "Get-VM" -ErrorAction SilentlyContinue)) {
    Write-Output "Hyper-V platform is present but the Hyper-V PowerShell module is not installed; cannot enumerate checkpoints."
    Stop-Transcript
    Exit 0
}

$cutoff = (Get-Date).AddDays($daysAgingInt)
$AgingCheckpoints = Get-VM | Get-VMSnapshot | Where-Object { $_.CreationTime -lt $cutoff }

if ($AgingCheckpoints) {
    $AgingCheckpoints | ForEach-Object {
        Write-Output "Checkpoint '$($_.Name)' on VM '$($_.VMName)' is older than $([math]::Abs($daysAgingInt)) day(s). Created on $($_.CreationTime). Please delete this checkpoint."
    }
    Stop-Transcript
    Exit 1
} else {
    Write-Output "There are no checkpoints older than $([math]::Abs($daysAgingInt)) day(s) that need to be deleted."
    Stop-Transcript
    Exit 0
}
