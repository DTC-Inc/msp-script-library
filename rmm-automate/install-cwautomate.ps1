## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $server     / $env:server     - REQUIRED. CW Automate Server hostname
## $token      / $env:token      - REQUIRED. CW Automate install token
## $locationid / $env:locationid - REQUIRED. CW Automate location id
## $username   / $env:username   - Domain username used to connect to remote computers
## $password   / $env:password   - Password for the domain account (omit to skip preset credentials)

param(
    # Each parameter defaults to its $env: counterpart so the script runs identically from the
    # command line (-server ...) or from an RMM that supplies the values as env variables. There
    # is no Read-Host and no Get-Credential: the script is non-interactive by design.
    [string]$server     = $env:server,
    [string]$token      = $env:token,
    [string]$locationid = $env:locationid,
    [string]$username   = $env:username,
    [string]$password   = $env:password
)

# This script requires PowerShell 7 or newer.

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
$missing = @()
if (-not $server)     { $missing += 'server' }
if (-not $token)      { $missing += 'token' }
if (-not $locationid) { $missing += 'locationid' }
if ($missing.Count -gt 0) {
    Write-Error "ERROR: Required input(s) not provided (set as -Parameter or `$env:): $($missing -join ', ')"
    exit 1
}

Start-Transcript 

# Set the time range to query
$today = Get-Date
$last30days = $today.AddDays(-30)

# Query Active Directory for computers that have checked in within the last 30 days
$computers = Get-ADComputer -Filter {LastLogonTimeStamp -gt $last30days} -Properties LastLogonTimeStamp

#Builds domain credentials to access computers from the supplied username/password
if ($password) {
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credentials = New-Object System.Management.Automation.PSCredential ($username,$securePassword)

} else {
    Write-Error "ERROR: No password provided (set -password or `$env:password). Cannot build credentials non-interactively."
    Stop-Transcript
    exit 1

}


$computers | ForEach-Object {
    $computerName = $_.Name
    Write-Output "Running on $computername."
    $ping = Test-Connection -Count 1 -ComputerName $computerName -Quiet
    if ($ping) {
        # Define the commands to run on the remote computer
        # Run the commands on the remote computer
        Invoke-Command -ComputerName $computername -Credential $using:credentials -ScriptBlock {
            param($server,$token,$locationid)

            $serviceName = Get-Service | Where {$_.Name -eq 'LTService'} | Select -ExpandProperty Name
            if ($serviceName) { 
                exit
            } else {
		$server = $server.ToString()
		$locationid = $locationid.ToString()
                $token = $token.ToString()
                [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072);
                Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Get-Nerdio/NMM/main/scripted-actions/modules/CMSP_Automate-Module.psm1');
                Install-Automate -Server $server -LocationID $locationid -Token $token -Transcript
            }
        } -ArgumentList $server,$token,$locationid
    } else {
        #Will display results in powershell window
        Write-Output "Could not connect to $computername"
    }
}
