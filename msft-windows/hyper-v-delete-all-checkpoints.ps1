# This was written by ChatGPT and modified by Nate Smith (nettts)

# Check if the script is running with administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script with administrator privileges." -ForegroundColor Red
    Exit 1
}

# Detect Hyper-V WITHOUT the ServerManager module / Get-WindowsFeature.
#
# Get-WindowsFeature lives in the ServerManager module, which is Server-only and is NOT
# supported in the 32-bit PowerShell host that RMMs (e.g. NinjaRMM) use to run scripts --
# calling it there throws "Thread failed to start" (System.Threading.ThreadStartException).
#
# The Hyper-V Virtual Machine Management service (vmms) and the Get-VM cmdlet are present
# only when the Hyper-V platform is installed, and both are bitness-safe on client + server.
if (-not (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V is not installed on this machine (vmms service not found)." -ForegroundColor Red
    Exit 1
}

if (-not (Get-Command -Name "Get-VM" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V platform is present but the Hyper-V PowerShell module is not installed; cannot manage checkpoints." -ForegroundColor Red
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
                Write-Host "Deleting checkpoint '$($checkpoint.Name)' for VM '$($vm.Name)'."
                # Remove only THIS checkpoint. The previous version piped $vmList into
                # Remove-VMSnapshot, which removed every snapshot on every VM on each loop
                # iteration.
                $checkpoint | Remove-VMSnapshot
            } catch {
                Write-Host "Error deleting checkpoint '$($checkpoint.Name)' for VM '$($vm.Name)': $_" -ForegroundColor Red
                # Keep going so one failure does not abort the rest of the cleanup.
                continue
            }
        }
    }
}
