# Get all backup jobs
$jobs = Get-VBRJob -WarningAction:SilentlyContinue

# Check if there are any jobs
if ($jobs.Count -eq 0) {
    Write-Host "No backup jobs found!"
    exit
}

# Iterate through each job and change the retention policy
foreach ($job in $jobs) {
    # Exclude jobs that contain the word "Copy" or "workstation" in their names
    if ($job.Name -match "Copy" -or $job.Name -match "workstation") {
        Write-Host "Skipping job '$($job.Name)' as it contains the word 'Copy' or 'workstation'."
        continue
    }
    
    # Get the job options
    $backupPolicy = Get-VBRJobOptions -Job $job
    
    # Change the retention policy to 400 restore points
    $backupPolicy.BackupStorageOptions.RetentionType = "Cycles"
    $backupPolicy.BackupStorageOptions.RetainCycles = 400
    
    # Set the new retention policy for the job
    Set-VBRJobOptions -Job $job -Options $backupPolicy
    
    Write-Host "Retention policy for job '$($job.Name)' has been updated to 400 restore points."
}

Write-Host "Retention policy update completed for all eligible jobs."
