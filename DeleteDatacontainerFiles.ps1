# Path to the folder
$FolderPath = "C:\datacontainer"

# Check if the folder exists
if (-Not (Test-Path -Path $FolderPath)) {
    Write-Output "Folder '$FolderPath' does not exist. Exiting script."
    Exit
}

# Get the current date minus 30 days
$DateThreshold = (Get-Date).AddDays(-30)

# Delete folders older than 30 days
Get-ChildItem -Path $FolderPath -Directory | Where-Object { $_.LastWriteTime -lt $DateThreshold } | ForEach-Object {
    Write-Output "Deleting folder: $($_.FullName)"
    Remove-Item -Path $_.FullName -Recurse -Force
}

Write-Output "Cleanup completed for folder '$FolderPath'."
