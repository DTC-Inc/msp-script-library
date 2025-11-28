## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## Required RMM Variables:
## - $LocalAdminUsername: Username for local admin account with rights to unjoin domain
## - $LocalAdminPassword: Password for local admin account
## - $WorkgroupName: Name of workgroup to join (default: WORKGROUP)
## - $Description: Ticket number or initials for tracking

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "domain-leave.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if (-not $Description) {
            Write-Host "Invalid input. Please try again."
            continue
        }

        $LocalAdminUsername = Read-Host "Enter local admin username"
        if (-not $LocalAdminUsername) {
            Write-Host "Local admin username is required."
            continue
        }

        $SecurePassword = Read-Host "Enter local admin password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $LocalAdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if (-not $LocalAdminPassword) {
            Write-Host "Local admin password is required."
            continue
        }

        $WorkgroupName = Read-Host "Enter workgroup name (press Enter for 'WORKGROUP')"
        if (-not $WorkgroupName) {
            $WorkgroupName = "WORKGROUP"
        }

        $ValidInput = 1
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }

    if ($null -eq $WorkgroupName) {
        $WorkgroupName = "WORKGROUP"
    }

    # Validate required RMM variables
    if ($null -eq $LocalAdminUsername -or $null -eq $LocalAdminPassword) {
        Write-Error "ERROR: LocalAdminUsername and LocalAdminPassword must be set when running from RMM"
        exit 1
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "=== Domain Leave Script ==="
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
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
