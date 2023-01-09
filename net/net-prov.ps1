# Wait for the ready!

$ready = "n"
while ($ready -ne "r") {
	$ready = Read-Host "Please patch in NICs to team. Type 'r' when ready"
	if ($ready -eq "r") {
			Write-Host "YEEET!"
	} else {
			Write-Host "Guess you're not ready. Hurry and patch in that first team!"
	}
}

$finished = "n"

$HyperV = Get-WindowsFeature | Where Installed | Select -ExpandProperty Name


Start-Sleep -Seconds 10

# Create NIC team(s) based off of link-state. Cables must be patched in for each loop.
$count = 0
while ( $finished -eq "n" ) {
	$count = $count + 1
	$nicList = Get-NetAdapter | Where -Property DriverFileName -notlike "usb*"| Where -Property Name -notlike vEthernet* | Where -Property Status -eq 'Up' | Where -Property InterFaceDescription -notcontains Hyper-V* | Select -ExpandProperty Name
	if ($count -eq 1) {
		if ($HyperV -eq "Hyper-V") {
			# Remove Hyper-V Teams
			Get-VMNetworkAdapter -managementOS | Where-Object -Property "name" -NotLike "Container NIC*" | Remove-VMNetworkAdapter
			Get-VMSwitch | Where-Object -Property name -NotLike "Default Switch" | Remove-VMSwitch -Force
			Start-Sleep -Seconds 10

			# Create Hyper-V initial Team
			New-VMSwitch -Name SET$count -netAdapterName $nicList -enableEmbeddedTeaming $true
			Rename-VmNetworkAdapter -Name SET$count -NewName vNIC1-SET$count -ManagementOs
			Add-VmNetworkAdapter -Name vNIC2-SET$count -SwitchName SET$count -ManagementOs 
		} else {
			Get-NetLbfoTeam | Remove-NetLbfoTeam -confirm:$false
			Start-Sleep -Seconds 10

			New-NetLbfoTeam -Name TEAM$count -TeamMembers $nicList -LoadBalancingAlgorithm Dynamic -TeamingMode SwitchIndependent -Confirm:$False
		}
	} else {
		if ($HyperV -eq "Hyper-V") {
			New-VMSwitch -Name SET$count -netAdapterName $nicList -enableEmbeddedTeaming $true -AllowManagementOs $False
		} else {
			New-NetLbfoTeam -Name TEAM$count -TeamMembers $nicList -LoadBalancingAlgorithm Dynamic -TeamingMode SwitchIndependent -Confirm:$False
		}	
	}
	$finished = Read-Host "Are you finished? y/n"
}