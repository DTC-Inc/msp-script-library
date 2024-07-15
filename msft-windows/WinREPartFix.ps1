# Get the Windows directory drive letter
$windowsDrive = (Get-WmiObject -Class Win32_OperatingSystem).SystemDrive

# Get the partition that corresponds to the Windows drive
$osPartition = Get-Partition | Where-Object { $_.DriveLetter -eq $windowsDrive.TrimEnd(':') }

# Output the partition number
$osPartition | Select-Object -Property PartitionNumber

# Define the shrink size in megabytes
$shrinkSizeMB = 250
$shrinkSize = $shrinkSizeMB * 1MB

# Check the free space and current size
$osDrive = Get-Volume -DriveLetter $windowsDrive.TrimEnd(':')

# Calculate the minimum shrinkable size
$minSize = $osPartition.Size - $osDrive.SizeRemaining

# Ensure there is enough free space to shrink
if ($osDrive.SizeRemaining -gt $shrinkSize) {
    # Shrink the OS partition by 250 megabytes
    $osPartition | Resize-Partition -Size ($osPartition.Size - $shrinkSize)
    
    # Output the new partition size
    $osPartition = Get-Partition | Where-Object { $_.DriveLetter -eq $windowsDrive.TrimEnd(':') }
    $osPartition | Select-Object -Property PartitionNumber, Size
} else {
    Write-Host "Not enough free space to shrink the partition by $shrinkSizeMB MB."
}

# Run the reagentc /info command and capture the output
$reagentcInfo = reagentc /info

# Initialize variables
$diskNumber = $null
$wrePartitionNumber = $null

# Define the regex patterns to match the disk and partition numbers
$diskPattern = "harddisk(\d+)"
$partitionPattern = "partition(\d+)"

# Parse the output to find the Disk and Partition numbers
foreach ($line in $reagentcInfo) {
    if ($line -match $diskPattern) {
        $diskNumber = $matches[1]
    }
    if ($line -match $partitionPattern) {
        $wrePartitionNumber = $matches[1]
    }
}

# Run the reagentc /disable command
reagentc /disable

# Check if diskNumber and wrePartitionNumber are found
if ($diskNumber -ne $null -and $wrePartitionNumber -ne $null) {
    Write-Host "Disk Number: $diskNumber"
    Write-Host "Partition Number: $wrePartitionNumber"

    # Optionally, store the results in variables for further use
    $global:DiskNumber = $diskNumber
    $global:WrePartitionNumber = $wrePartitionNumber

    # Delete the partition
    $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
    if ($partition) {
        Write-Host "Deleting Partition Number: $wrePartitionNumber on Disk Number: $diskNumber"
        Remove-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber -Confirm:$false
        Write-Host "Partition deleted successfully."
    } else {
        Write-Host "Partition not found."
    }

    # Determine if the disk is GPT or MBR
    $disk = Get-Disk -Number $diskNumber
    $isGPT = $disk.PartitionStyle -eq 'GPT'

    if ($isGPT) {
        # Create a new partition with GPT settings
        Write-Host "Disk is GPT. Creating new partition."
        $disk | New-Partition -UseMaximumSize -GptType "de94bba4-06d1-4d40-a16a-bfd50179d6ac" | Out-Null
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
        $partition | Set-Partition -GptAttributes 0x8000000000000001
    } else {
        # Create a new partition with MBR settings
        Write-Host "Disk is MBR. Creating new partition."
        $disk | New-Partition -UseMaximumSize -MbrType 27 | Out-Null
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
        $partition | Set-Partition -NewDriveLetter 'X' -MbrType 27
    }

    # Format the new partition
    Write-Host "Formatting the new partition."
    $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows RE tools" -Quick

    Write-Host "Partition created and formatted successfully."

    # Re-enable Windows RE
    reagentc /enable
    Write-Host "Windows RE enabled successfully."

} else {
    Write-Host "Failed to find Disk Number and Partition Number in the output."
}

