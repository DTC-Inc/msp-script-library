# This was written by ChatGPT and modified by Nate Smith (nettts)

# Check if the script is running with administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script with administrator privileges." -ForegroundColor Red
    Exit 1
}

# Check if Hyper-V feature is installed
if (-not (Get-WindowsFeature -Name Hyper-V | Where-Object { $_.Installed })) {
    Write-Host "Hyper-V feature is not installed on this machine." -ForegroundColor Red
    Exit 1
}

# Delete all Hyper-V snapshots
$vmList = Get-VM

if ($vmList.Count -eq 0) {
    Write-Host "No virtual machines found on this host." -ForegroundColor Yellow
    return
}

foreach ($vm in $vmList) {
    $checkpointList = Get-VMSnapshot -VMName $vm.Name
    if ($checkpointList.Count -eq 0) {
        Write-Host "No checkpoints found for VM $($vm.Name)." -ForegroundColor Yellow
    } else {
        foreach ($checkpoint in $checkpointList) {
            try { 
                Write-Host "Deleting checkpoint $checkpoint for $vm"
                $vmList| Remove-VMSnapshot

            } catch {
                Write-Host "Error deleting checkpoint $checkpiont for $vm."
                Exit 1
            
            }
        }
    }
}
