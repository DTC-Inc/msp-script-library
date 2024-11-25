# Script to detect disabled backup jobs in Veeam
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

# Get all jobs
$jobs = Get-VBRJob

# Check for disabled jobs
$disabledJobs = $jobs | Where-Object {$_.IsScheduleEnabled -eq $false}

if ($disabledJobs) {
    # Output the names of disabled jobs (or any custom message for NinjaRMM alert)
    Write-Output "Disabled backup jobs detected: $($disabledJobs.Name -join ', ')"
    # Exit 1  # Return a non-zero exit code for alert
} else {
    Write-Output "All backup jobs are enabled."
    # Exit 0  # Return 0 if no issues are found
}
