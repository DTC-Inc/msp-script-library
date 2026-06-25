## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $ticketNumber  / $env:ticketNumber  - Ticket # for audit trail (used as the job description)
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    [string]$ticketNumber  = $env:ticketNumber,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

# Make sure PSModulePath includes Veeam Console
Write-Host "Installing Veeam PowerShell Module if not installed already."
$MyModulePath = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MyModulePath"
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

# --- Input handling: non-interactive (no Read-Host) ----------------------
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\veeam-add-backup-repo.log"
} else {
    $logPath = "$env:WINDIR\logs\veeam-add-backup-repo.log"
}
Write-Host "Reference Ticket #$ticketNumber"

Start-Transcript -Path $logPath

# Set the desired block size (8 MB) in bytes
$blockSizeBytes = 5

# Get all backup jobs
$backupJobs = Get-VBRJob

# Loop through each job and modify block size
foreach ($job in $backupJobs) {
    try {
        # Check if the job is a backup job (not a replication job, for example)
        if ($job.TypeToString -eq "Backup Copy") {
            Write-Host "Backup job is a Backup Copy. Not setting block size."

        } else {
            # Set the new block size for the job
            $job | Set-VBRJobAdvancedStorageOptions -StorageBlockSize 6
            Write-Host "Block size set to 4 MB for job: $($job.Name)"
    }

    } catch {
        Write-Host "Error occurred while setting block size for job $($job.Name): $_.Exception.Message"
    }
}
Stop-Transcript