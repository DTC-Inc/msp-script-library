## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## Required RMM Variables:
## - $DomainName: FQDN of domain to join (e.g., contoso.com)
## - $DomainUsername: Username with rights to join computers to domain (can be DOMAIN\Username or UPN format)
## - $DomainPassword: Password for domain account
## - $DefaultLoginUser: Default user to show on Windows login screen (e.g., "DOMAIN\username" or "username@domain.com")
##
## Optional RMM Variables:
## - $Description: Ticket number or initials for tracking (defaults to "Automated Domain Join")

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "domain-join.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        $Description = Read-Host "Please enter the ticket # and, or your initials (press Enter for 'Automated Domain Join')"
        if (-not $Description) {
            $Description = "Automated Domain Join"
        }

        $DomainName = Read-Host "Enter domain name to join (FQDN, e.g., contoso.com)"
        if (-not $DomainName) {
            Write-Host "Domain name is required."
            continue
        }

        $DomainUsername = Read-Host "Enter domain username with join rights (DOMAIN\Username or user@domain.com)"
        if (-not $DomainUsername) {
            Write-Host "Domain username is required."
            continue
        }

        $SecurePassword = Read-Host "Enter domain password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $DomainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if (-not $DomainPassword) {
            Write-Host "Domain password is required."
            continue
        }

        $DefaultLoginUser = Read-Host "Enter default login user (e.g., DOMAIN\username or username@domain.com)"
        if (-not $DefaultLoginUser) {
            Write-Host "Default login user is required."
            continue
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
        $Description = "Automated Domain Join"
    }

    # Validate required RMM variables
    if ($null -eq $DomainName -or $null -eq $DomainUsername -or $null -eq $DomainPassword -or $null -eq $DefaultLoginUser) {
        Write-Error "ERROR: DomainName, DomainUsername, DomainPassword, and DefaultLoginUser must be set when running from RMM"
        exit 1
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "=== Domain Join Script ==="
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Domain Name: $DomainName"
Write-Host "Domain Username: $DomainUsername"
Write-Host "Default Login User: $DefaultLoginUser"
Write-Host ""

try {
    # Check current computer status
    $ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
    $CurrentName = $ComputerSystem.Name
    $CurrentDomain = $ComputerSystem.Domain
    $PartOfDomain = $ComputerSystem.PartOfDomain

    Write-Host "Current computer name: $CurrentName"
    Write-Host "Current domain/workgroup: $CurrentDomain"
    Write-Host "Part of domain: $PartOfDomain"
    Write-Host ""

    # Create credential object
    $SecurePasswordObj = ConvertTo-SecureString $DomainPassword -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ($DomainUsername, $SecurePasswordObj)

    # Build domain join parameters (simplified - no OU path, no rename)
    $JoinParams = @{
        DomainName = $DomainName
        Credential = $Credential
        Force = $true
        Verbose = $true
    }

    Write-Host "Joining domain '$DomainName' (default Computers container)..."

    # Join the domain
    Add-Computer @JoinParams

    Write-Host ""
    Write-Host "SUCCESS: Computer has been joined to domain '$DomainName'"

    # Set default login user
    Write-Host ""
    Write-Host "Setting default login user to: $DefaultLoginUser"

    $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    try {
        Set-ItemProperty -Path $RegPath -Name "DefaultUserName" -Value $DefaultLoginUser -Force
        Write-Host "Default login user configured successfully"
    } catch {
        Write-Warning "Failed to set default login user: $($_.Exception.Message)"
        Write-Warning "You may need to set this manually after reboot"
    }

    Write-Host ""
    Write-Host "A reboot is required to complete the domain join."
    Write-Host "Rebooting in 10 seconds..."
    Write-Host "Press Ctrl+C to cancel reboot"

    Start-Sleep -Seconds 10

    Write-Host "Initiating reboot..."
    Restart-Computer -Force

} catch {
    Write-Error "ERROR: Failed to join domain"
    Write-Error "Error message: $($_.Exception.Message)"
    Write-Error "Error details: $_"

    # Provide common troubleshooting hints
    Write-Host ""
    Write-Host "Common issues:"
    Write-Host "- Verify domain credentials have rights to join computers"
    Write-Host "- Check network connectivity to domain controller"
    Write-Host "- Verify domain name is correct FQDN"
    Write-Host "- Check DNS settings point to domain DNS servers"

    Stop-Transcript
    exit 1
}

Stop-Transcript
