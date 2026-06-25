## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
##
## Required RMM Variables:
## - $LocalAdminUsername / $env:LocalAdminUsername: Username for local admin account with rights to unjoin domain
## - $LocalAdminPassword / $env:LocalAdminPassword: Password for local admin account
## - $WorkgroupName / $env:WorkgroupName: Name of workgroup to join (default: WORKGROUP)
## - $Description / $env:Description: Ticket number or initials for tracking
## - $RMMScriptPath / $env:RMMScriptPath: Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs identically from the
    # command line (-LocalAdminUsername ...) or from an RMM that supplies values as env variables.
    [string]$Description        = $env:Description,
    [string]$LocalAdminUsername = $env:LocalAdminUsername,
    [string]$LocalAdminPassword = $env:LocalAdminPassword,
    [string]$WorkgroupName      = $env:WorkgroupName,
    [string]$RMMScriptPath      = $env:RMMScriptPath
)

$ScriptLogName = "domain-leave.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if ($null -eq $Description -or $Description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

if (-not $WorkgroupName) {
    $WorkgroupName = "WORKGROUP"
}

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
if (-not $LocalAdminUsername -or -not $LocalAdminPassword) {
    Write-Error "ERROR: LocalAdminUsername and LocalAdminPassword must be set when running from RMM"
    exit 1
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "=== Domain Leave Script ==="
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "Workgroup Name: $WorkgroupName"
Write-Host "Local Admin Username: $LocalAdminUsername"
Write-Host ""

try {
    # Check if computer is currently domain joined
    $ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
    $CurrentDomain = $ComputerSystem.Domain
    $PartOfDomain = $ComputerSystem.PartOfDomain

    Write-Host "Current computer name: $($ComputerSystem.Name)"
    Write-Host "Current domain/workgroup: $CurrentDomain"
    Write-Host "Part of domain: $PartOfDomain"
    Write-Host ""

    if (-not $PartOfDomain) {
        Write-Host "Computer is not currently joined to a domain. No action needed."
        Stop-Transcript
        exit 0
    }

    # Create credential object
    $SecurePasswordObj = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ($LocalAdminUsername, $SecurePasswordObj)

    Write-Host "Removing computer from domain '$CurrentDomain' and joining workgroup '$WorkgroupName'..."

    # Remove from domain and join workgroup
    Remove-Computer -UnjoinDomainCredential $Credential -WorkgroupName $WorkgroupName -Force -Verbose

    Write-Host ""
    Write-Host "SUCCESS: Computer has been removed from domain '$CurrentDomain'"
    Write-Host "Computer will join workgroup '$WorkgroupName' after reboot"
    Write-Host ""
    Write-Host "Rebooting in 10 seconds..."
    Write-Host "Press Ctrl+C to cancel reboot"

    Start-Sleep -Seconds 10

    Write-Host "Initiating reboot..."
    Restart-Computer -Force

} catch {
    Write-Error "ERROR: Failed to leave domain"
    Write-Error "Error message: $($_.Exception.Message)"
    Write-Error "Error details: $_"
    Stop-Transcript
    exit 1
}

Stop-Transcript
