# This script requires PowerShell 7 or newer.

Start-Transcript 

# Detect interactive script or not.
if ($Server -eq $null) {
    $server = Read-Host "Input CW Automate Server hostname" | Out-String
}

if ($token -eq $null) {
    $token = Read-Host "Input CW Automate intall token" | Out-String
}

if ($locationId -eq $null) {
    $locationid = Read-Host "Input CW Automate location id" | Out-String
}

# Set the time range to query
$today = Get-Date
$last30days = $today.AddDays(-30)

# Query Active Directory for computers that have checked in within the last 30 days
$computers = Get-ADComputer -Filter {LastLogonTimeStamp -gt $last30days} -Properties LastLogonTimeStamp

#Prompts for domain credentials to access computer if credentials are predefined
if ($password) {
    $credentials = New-Object System.Management.Automation.PSCredential ($username,$password)

} else {
  $credentials = Get-Credential

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
