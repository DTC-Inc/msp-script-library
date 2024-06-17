# Script to run checkdisk with bad block detection and repair, and restart the system

# Function to run chkdsk
function Run-CheckDisk {
    $disk = "C:"  # Change this to the drive letter you want to check if it's not C:
    $arguments = "/f /r $disk"
    
    # Automatically answer "yes" to the prompt to run on next restart
    cmd /c "echo Y| chkdsk $disk /r"
}

# Run the function to initiate checkdisk
Run-CheckDisk

# Restart the computer
Restart-Computer -Force
