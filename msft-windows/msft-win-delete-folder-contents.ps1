# Define the folder path to check
$folderPath = "C:\Path\To\Your\Folder"

# Define the age threshold in days
$daysThreshold = 90

# Check if the folder exists
if (Test-Path -Path $folderPath) {
    # Get current date
    $currentDate = Get-Date
    
    # Calculate the cutoff date based on the threshold
    $cutoffDate = $currentDate.AddDays(-$daysThreshold)
    
    # Get items older than the threshold
    $oldItems = Get-ChildItem -Path $folderPath -Recurse | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
    # If there are items to delete
    if ($oldItems.Count -gt 0) {
        Write-Host "Found $($oldItems.Count) items older than $daysThreshold days. Deleting..."
        
        # Remove the items
        foreach ($item in $oldItems) {
            Remove-Item -Path $item.FullName -Force -Recurse -ErrorAction SilentlyContinue
            if ($?) {
                Write-Host "Deleted: $($item.FullName)"
            } else {
                Write-Host "Failed to delete: $($item.FullName)" -ForegroundColor Red
            }
        }
        
        Write-Host "Cleanup completed."
    } else {
        Write-Host "No items older than $daysThreshold days found in $folderPath."
    }
} else {
    Write-Host "Folder does not exist: $folderPath"
}