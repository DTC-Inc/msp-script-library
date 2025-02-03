# Get all logical drives that are internal, not network, and fixed drives
$drives = Get-WmiObject Win32_LogicalDisk | Where-Object {
    $_.DriveType -eq 3 -and $_.Size -gt 10GB
}

foreach ($drive in $drives) {
    $freeSpaceGB = [math]::Round($drive.FreeSpace / 1GB, 2)
    $totalSizeGB = [math]::Round($drive.Size / 1GB, 2)
    
    Write-Host "Drive $($drive.DeviceID): Total: $totalSizeGB GB, Free: $freeSpaceGB GB"
    
    if ($freeSpaceGB -lt 4.3) {
        Write-Warning "ALERT: Drive $($drive.DeviceID) has less than 4.3GB free!"
    }
}
