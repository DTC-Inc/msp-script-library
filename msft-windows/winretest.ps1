# Define the log file path
$logFile = "C:\dtc\logs\winreresize.log"

# Function to log messages
function Log-Message {
    param (
        [string]$message,
        [string]$level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$level] $message"
    Add-Content -Path $logFile -Value $logEntry
}

# Error handling function
function Handle-Error {
    param (
        [string]$message
    )
    Log-Message -message $message -level "ERROR"
    throw $message
}

# Start of the script
Log-Message "Script started."

try {
    # Get the Windows directory drive letter
    $windowsDrive = (Get-WmiObject -Class Win32_OperatingSystem).SystemDrive
    Log-Message "Windows drive: $windowsDrive"

    # Get the partition that corresponds to the Windows drive
    $osPartition = Get-Partition | Where-Object { $_.DriveLetter -eq $windowsDrive.TrimEnd(':') }
    if (-not $osPartition) { Handle-Error "Failed to get the OS partition." }
    Log-Message "OS partition obtained."

    # Output the partition number
    $osPartition | Select-Object -Property PartitionNumber | ForEach-Object { Log-Message "Partition number: $_.PartitionNumber" }

    # Define the shrink size in megabytes
    $shrinkSizeMB = 250
    $shrinkSize = $shrinkSizeMB * 1MB

    # Check the free space and current size
    $osDrive = Get-Volume -DriveLetter $windowsDrive.TrimEnd(':')
    if (-not $osDrive) { Handle-Error "Failed to get the OS drive volume." }
    Log-Message "OS drive volume obtained."

    # Calculate the minimum shrinkable size
    $minSize = $osPartition.Size - $osDrive.SizeRemaining

    # Ensure there is enough free space to shrink
    if ($osDrive.SizeRemaining -gt $shrinkSize) {
        Log-Message "Sufficient free space available. Proceeding to shrink partition by $shrinkSizeMB MB."
        
        # Shrink the OS partition by 250 megabytes
        $osPartition | Resize-Partition -Size ($osPartition.Size - $shrinkSize)
        Log-Message "Partition resized."

        # Output the new partition size
        $osPartition = Get-Partition | Where-Object { $_.DriveLetter -eq $windowsDrive.TrimEnd(':') }
        $osPartition | Select-Object -Property PartitionNumber, Size | ForEach-Object { Log-Message "New partition size: $_.Size" }
    } else {
        Handle-Error "Not enough free space to shrink the partition by $shrinkSizeMB MB."
    }

    # Run the reagentc /info command and capture the output
    $reagentcInfo = reagentc /info
    if (-not $reagentcInfo) { Handle-Error "Failed to run reagentc /info command." }
    Log-Message "reagentc /info command output obtained."

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
            Log-Message "Disk number found: $diskNumber"
        }
        if ($line -match $partitionPattern) {
            $wrePartitionNumber = $matches[1]
            Log-Message "Partition number found: $wrePartitionNumber"
        }
    }

    # Run the reagentc /disable command
    reagentc /disable
    Log-Message "Windows RE disabled."

    # Check if diskNumber and wrePartitionNumber are found
    if ($diskNumber -ne $null -and $wrePartitionNumber -ne $null) {
        Log-Message "Disk Number: $diskNumber, Partition Number: $wrePartitionNumber"

        # Optionally, store the results in variables for further use
        $global:DiskNumber = $diskNumber
        $global:WrePartitionNumber = $wrePartitionNumber

        # Delete the partition
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
        if ($partition) {
            Log-Message "Deleting Partition Number: $wrePartitionNumber on Disk Number: $diskNumber"
            Remove-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber -Confirm:$false
            Log-Message "Partition deleted successfully."
        } else {
            Handle-Error "Partition not found."
        }

        # Determine if the disk is GPT or MBR
        $disk = Get-Disk -Number $diskNumber
        $isGPT = $disk.PartitionStyle -eq 'GPT'

        if ($isGPT) {
            # Create a new partition with GPT settings
            Log-Message "Disk is GPT. Creating new partition."
            $disk | New-Partition -UseMaximumSize -GptType "de94bba4-06d1-4d40-a16a-bfd50179d6ac" | Out-Null
            $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
            $partition | Set-Partition -GptAttributes 0x8000000000000001
        } else {
            # Create a new partition with MBR settings
            Log-Message "Disk is MBR. Creating new partition."
            $disk | New-Partition -UseMaximumSize -MbrType 27 | Out-Null
            $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $wrePartitionNumber
            $partition | Set-Partition -NewDriveLetter 'X' -MbrType 27
        }

        # Format the new partition
        Log-Message "Formatting the new partition."
        $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "Windows RE tools" -Quick
        Log-Message "Partition created and formatted successfully."

        # Re-enable Windows RE
        reagentc /enable
        Log-Message "Windows RE enabled successfully."

    } else {
        Handle-Error "Failed to find Disk Number and Partition Number in the output."
    }

} catch {
    Handle-Error "An error occurred: $_"
}

Log-Message "Script completed."
