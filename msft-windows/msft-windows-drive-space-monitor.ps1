# Get all logical drives that are internal, not network, and fixed drives
$drives = Get-WmiObject Win32_LogicalDisk | Where-Object {
    $_.DriveType -eq 3 -and $_.Size -gt 20GB
}

$lowSpaceDrives = @()

foreach ($drive in $drives) {
    $freeSpaceGB = [math]::Round($drive.FreeSpace / 1GB, 2)
    $totalSizeGB = [math]::Round($drive.Size / 1GB, 2)
    
    Write-Host "Drive $($drive.DeviceID): Total: $totalSizeGB GB, Free: $freeSpaceGB GB"
    
    if ($freeSpaceGB -lt 4.3) {
        Write-Warning "ALERT: Drive $($drive.DeviceID) has less than 4.3GB free!"
        $lowSpaceDrives += $drive
    }
}

# Check if there are any low space drives
if ($lowSpaceDrives.Count -eq 0) {
    Write-Host "No drives with low disk space found. Skipping large file check." -ForegroundColor Green
    return
}

# Select the drive with the lowest free space
$Volume = ($lowSpaceDrives | Sort-Object FreeSpace | Select-Object -First 1).DeviceID + "\"

Write-Host "Scanning largest files in $Volume" -ForegroundColor Yellow

# Check if the volume exists
if (-Not (Test-Path -Path $Volume)) {
    Write-Host "The volume ${Volume} does not exist. Please provide a valid volume." -ForegroundColor Red
    return
}

# Get all files in the volume only if low space condition exists
if ($lowSpaceDrives.Count -gt 0) {
    $Items = Get-ChildItem -Path $Volume -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            # Get the size of individual files in GB
            [PSCustomObject]@{
                Name = $_.FullName
                SizeGB = "{0:N2}" -f ($_.Length / 1GB)
            }
        }

    # Sort items by size in descending order and select the top 10
    $LargestItems = $Items | Sort-Object -Property SizeGB -Descending | Select-Object -First 10

    # Output the results
    Write-Host "The 10 largest files in ${Volume}:" -ForegroundColor Green
    $LargestItems | Format-Table -Property Name, SizeGB -AutoSize
}
