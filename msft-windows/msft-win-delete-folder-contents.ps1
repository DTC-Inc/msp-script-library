# Define the folder path to check
$folderPath = "$FolderLocation"

# Define the age threshold in days
$daysThreshold = $NumberOfDays

# Check if the folder exists
if (Test-Path -Path $folderPath) {
    # Get current date
    $currentDate = Get-Date
    
    # Calculate the cutoff date based on the threshold
    $cutoffDate = $currentDate.AddDays(-$daysThreshold)
    
    # Get all items older than the threshold
    $allOldItems = Get-ChildItem -Path $folderPath -Recurse | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    # If there are items to delete
    if ($allOldItems.Count -gt 0) {
        Write-Host "Found $($allOldItems.Count) items older than $daysThreshold days."
        
        # Separate files and folders
        $oldFiles = $allOldItems | Where-Object { -not $_.PSIsContainer }
        $oldFolders = $allOldItems | Where-Object { $_.PSIsContainer }
        
        # Sort folders by depth (deepest first) to avoid the error
        $oldFolders = $oldFolders | Sort-Object -Property FullName -Descending
        
        # Delete files first
        if ($oldFiles.Count -gt 0) {
            Write-Host "Deleting $($oldFiles.Count) files..."
            foreach ($file in $oldFiles) {
                try {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    Write-Host "Deleted file: $($file.FullName)"
                } catch {
                    Write-Host "Failed to delete file: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        
        # Then delete folders (deepest first)
        if ($oldFolders.Count -gt 0) {
            Write-Host "Deleting $($oldFolders.Count) folders..."
            foreach ($folder in $oldFolders) {
                try {
                    # Check if folder still exists (might have been deleted as part of parent folder)
                    if (Test-Path -Path $folder.FullName) {
                        Remove-Item -Path $folder.FullName -Force -ErrorAction Stop
                        Write-Host "Deleted folder: $($folder.FullName)"
                    }
                } catch {
                    Write-Host "Failed to delete folder: $($folder.FullName) - $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        
        Write-Host "Cleanup completed."
    } else {
        Write-Host "No items older than $daysThreshold days found in $folderPath."
    }
} else {
    Write-Host "Folder does not exist: $folderPath"
}
