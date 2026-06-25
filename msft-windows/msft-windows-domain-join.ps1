## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
##
## Required RMM Variables:
## - $DomainName / $env:DomainName: FQDN of domain to join (e.g., contoso.com)
## - $DomainUsername / $env:DomainUsername: Username with rights to join computers to domain (DOMAIN\Username or UPN)
## - $DomainPassword / $env:DomainPassword: Password for domain account
## - $DefaultLoginUser / $env:DefaultLoginUser: Default user to show on Windows login screen ("DOMAIN\username" or "username@domain.com")
##
## Optional RMM Variables:
## - $Description / $env:Description: Ticket number or initials for tracking (defaults to "Automated Domain Join")

param(
    # Each parameter defaults to its $env: counterpart so the script runs identically from the
    # command line (-DomainName ...) or from an RMM that supplies the values as env variables.
    [string]$Description      = $env:Description,
    [string]$DomainName       = $env:DomainName,
    [string]$DomainUsername   = $env:DomainUsername,
    [string]$DomainPassword   = $env:DomainPassword,
    [string]$DefaultLoginUser = $env:DefaultLoginUser,
    [string]$RMMScriptPath    = $env:RMMScriptPath
)

$ScriptLogName = "domain-join.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if (-not $Description) {
    $Description = "Automated Domain Join"
}

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
$missing = @()
if (-not $DomainName)       { $missing += 'DomainName' }
if (-not $DomainUsername)   { $missing += 'DomainUsername' }
if (-not $DomainPassword)   { $missing += 'DomainPassword' }
if (-not $DefaultLoginUser) { $missing += 'DefaultLoginUser' }
if ($missing.Count -gt 0) {
    Write-Error "ERROR: Required input(s) not provided (set as -Parameter or `$env:): $($missing -join ', ')"
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

Write-Host "=== Domain Join Script ==="
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
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
