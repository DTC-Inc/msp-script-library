# Find-VeeamS3OrphanedBackupData.ps1
# This script finds orphaned backup data in Veeam backup copy jobs or repositories targeting S3 storage

param (
    [Parameter(Mandatory = $false)]
    [string]$VBRServer = "localhost",
    
    [Parameter(Mandatory = $false)]
    [string]$JobName,
    
    [Parameter(Mandatory = $false)]
    [string]$RepositoryName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Jobs", "Repositories", "Both")]
    [string]$AnalysisMode = "Both",
    
    [Parameter(Mandatory = $false)]
    [switch]$DetailedReport,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportCSV,
    
    [Parameter(Mandatory = $false)]
    [string]$CSVPath = ".\VeeamOrphanedBackups_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# Import Veeam Module
try {
    Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
}
catch {
    Write-Error "Failed to load Veeam PowerShell module. Please ensure Veeam Backup & Replication is installed."
    Write-Error "Error: $_"
    exit 1
}

# Connect to VBR Server
try {
    Write-Host "Connecting to Veeam Backup & Replication server ($VBRServer)..." -ForegroundColor Yellow
    Connect-VBRServer -Server $VBRServer
    Write-Host "Connected successfully." -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to VBR server: $_"
    exit 1
}

function Get-VeeamS3BackupCopyJobs {
    param (
        [string]$JobName
    )
    
    try {
        if ($JobName) {
            $backupCopyJobs = Get-VBRBackupCopyJob | Where-Object { 
                $_.Name -like "*$JobName*" -and 
                $_.Target.Type -eq "Cloud" 
            }
        }
        else {
            $backupCopyJobs = Get-VBRBackupCopyJob | Where-Object { 
                $_.Target.Type -eq "Cloud" 
            }
        }
        
        return $backupCopyJobs
    }
    catch {
        Write-Error "Failed to retrieve backup copy jobs: $_"
        return $null
    }
}

function Get-VeeamS3Repositories {
    param (
        [string]$RepositoryName
    )
    
    try {
        if ($RepositoryName) {
            $s3Repos = Get-VBRBackupRepository | Where-Object { 
                $_.Name -like "*$RepositoryName*" -and 
                ($_.Type -eq "AmazonS3" -or $_.Type -eq "S3Compatible" -or 
                 $_.Type -match "S3")
            }
        }
        else {
            $s3Repos = Get-VBRBackupRepository | Where-Object { 
                $_.Type -eq "AmazonS3" -or $_.Type -eq "S3Compatible" -or 
                $_.Type -match "S3"
            }
        }
        
        return $s3Repos
    }
    catch {
        Write-Error "Failed to retrieve S3 repositories: $_"
        return $null
    }
}

function Get-OrphanedBackupData {
    param (
        [Parameter(Mandatory = $true)]
        [PSObject]$BackupCopyJob
    )
    
    try {
        Write-Host "Analyzing job: $($BackupCopyJob.Name)" -ForegroundColor Cyan
        
        # Get backup objects from repository
        $jobBackups = Get-VBRBackup -Job $BackupCopyJob
        
        if (-not $jobBackups) {
            Write-Host "  No backups found for this job" -ForegroundColor Yellow
            return $null
        }
        
        $orphanedData = @()
        
        foreach ($backup in $jobBackups) {
            # Get storage data
            $storageData = [Veeam.Backup.Core.CBackupSession]::GetRepositoryStorageInfo($backup.Id)
            
            if (-not $storageData) {
                continue
            }
            
            # Get all files from storage
            $allBackupFiles = $backup.GetAllStorageFiles()
            
            # Get files from the active points
            $activePoints = $backup.GetPoints()
            $activeFiles = @()
            
            foreach ($point in $activePoints) {
                $pointFiles = $point.GetStorageFiles()
                $activeFiles += $pointFiles
            }
            
            # Find orphaned files
            $orphanedFiles = $allBackupFiles | Where-Object { 
                $file = $_
                -not ($activeFiles | Where-Object { $_.Name -eq $file.Name })
            }
            
            if ($orphanedFiles) {
                foreach ($file in $orphanedFiles) {
                    $orphanObject = [PSCustomObject]@{
                        JobName = $BackupCopyJob.Name
                        BackupName = $backup.Name
                        FileName = $file.Name
                        FileSize = [Math]::Round($file.Size / 1GB, 2)
                        FileSizeBytes = $file.Size
                        Path = $file.Path
                        CreationTime = $file.CreationTime
                        Source = "Backup Copy Job"
                        RepositoryName = $backup.RepositoryName
                    }
                    
                    $orphanedData += $orphanObject
                }
            }
        }
        
        return $orphanedData
    }
    catch {
        Write-Error "Error analyzing job $($BackupCopyJob.Name): $_"
        return $null
    }
}

function Get-OrphanedRepositoryData {
    param (
        [Parameter(Mandatory = $true)]
        [PSObject]$Repository
    )
    
    try {
        Write-Host "Analyzing repository: $($Repository.Name)" -ForegroundColor Cyan
        
        # Get all backups in this repository
        $repoBackups = Get-VBRBackup | Where-Object { $_.RepositoryId -eq $Repository.Id }
        
        if (-not $repoBackups -or $repoBackups.Count -eq 0) {
            Write-Host "  No backups found in this repository" -ForegroundColor Yellow
            return $null
        }
        
        $orphanedData = @()
        
        foreach ($backup in $repoBackups) {
            Write-Host "  Processing backup: $($backup.Name)" -ForegroundColor DarkGray
            
            try {
                # Get all restore points
                $activePoints = $backup.GetPoints()
                
                if (-not $activePoints -or $activePoints.Count -eq 0) {
                    Write-Host "    No restore points found for this backup" -ForegroundColor DarkGray
                    continue
                }
                
                $activeFiles = @()
                
                # For each restore point, get its storage files
                foreach ($point in $activePoints) {
                    try {
                        $pointFiles = $point.GetStorageFiles()
                        if ($pointFiles) {
                            $activeFiles += $pointFiles
                        }
                    }
                    catch {
                        Write-Host "    Error getting files for restore point: $_" -ForegroundColor DarkGray
                    }
                }
                
                # For S3 repositories, we can't scan the files directly
                # Instead, we can use the backup's FindAllStorages method if available
                try {
                    $potentialOrphans = @()
                    
                    # Get all files from backup object
                    Write-Host "    Checking for orphaned files in backup metadata..." -ForegroundColor DarkGray
                    
                    # Use reflection to see if GetAllStorages method exists
                    $backupType = $backup.GetType()
                    $getAllStoragesMethod = $backupType.GetMethod("GetAllStorages")
                    
                    if ($getAllStoragesMethod) {
                        $allStorages = $getAllStoragesMethod.Invoke($backup, $null)
                        if ($allStorages) {
                            $potentialOrphans = $allStorages | Where-Object { $_.RepositoryId -eq $Repository.Id }
                            Write-Host "    Found $($potentialOrphans.Count) potential storage items in backup metadata" -ForegroundColor DarkGray
                        }
                    }
                    else {
                        Write-Host "    GetAllStorages method not available on backup object" -ForegroundColor DarkGray
                    }
                    
                    # Compare active files with all potential storages to find orphans
                    if ($potentialOrphans.Count -gt 0 -and $activeFiles.Count -gt 0) {
                        $orphanedFiles = $potentialOrphans | Where-Object { 
                            $file = $_
                            -not ($activeFiles | Where-Object { $_.Id -eq $file.Id -or $_.Name -eq $file.Name })
                        }
                        
                        Write-Host "    Found $($activeFiles.Count) active files and $($orphanedFiles.Count) potentially orphaned files" -ForegroundColor DarkGray
                        
                        if ($orphanedFiles) {
                            foreach ($file in $orphanedFiles) {
                                $fileSize = if ($file.Size) { $file.Size } else { 0 }
                                $orphanObject = [PSCustomObject]@{
                                    JobName = $backup.JobName
                                    BackupName = $backup.Name
                                    FileName = $file.Name
                                    FileSize = [Math]::Round($fileSize / 1GB, 2)
                                    FileSizeBytes = $fileSize
                                    Path = if ($file.Path) { $file.Path } else { "S3 Storage" }
                                    CreationTime = if ($file.CreationTime) { $file.CreationTime } else { Get-Date }
                                    Source = "Repository"
                                    RepositoryName = $Repository.Name
                                }
                                
                                $orphanedData += $orphanObject
                            }
                        }
                    }
                    else {
                        # Alternative approach - try to detect orphans based on point data
                        Write-Host "    Using alternative approach to detect orphaned files..." -ForegroundColor DarkGray
                        
                        # Get info from property bag if available
                        $storageData = $null
                        
                        try {
                            if ($backup.PSObject.Properties['Info'] -and $backup.Info.PSObject.Properties['Storage']) {
                                $storageData = $backup.Info.Storage
                            }
                        }
                        catch {
                            Write-Host "    Cannot access storage info properties: $_" -ForegroundColor DarkGray
                        }
                        
                        if ($storageData) {
                            # Analyze storage data
                            Write-Host "    Found storage data in backup info" -ForegroundColor DarkGray
                            
                            # Extract any useful information from storage data
                            # This is very version-dependent, so we're providing basic information
                            $orphanObject = [PSCustomObject]@{
                                JobName = $backup.JobName
                                BackupName = $backup.Name
                                FileName = "See Veeam console for details"
                                FileSize = 0
                                FileSizeBytes = 0
                                Path = "S3 Storage"
                                CreationTime = Get-Date
                                Source = "Repository"
                                RepositoryName = $Repository.Name
                                AdditionalInfo = "Unable to directly scan S3 storage. Check Veeam console for detailed information."
                            }
                            
                            $orphanedData += $orphanObject
                        }
                        else {
                            Write-Host "    No storage data found for this backup" -ForegroundColor DarkGray
                        }
                    }
                }
                catch {
                    Write-Host "    Error analyzing backup storages: $_" -ForegroundColor DarkGray
                    
                    # Provide information about inability to analyze S3 repository
                    $orphanObject = [PSCustomObject]@{
                        JobName = $backup.JobName
                        BackupName = $backup.Name
                        FileName = "N/A"
                        FileSize = 0
                        FileSizeBytes = 0
                        Path = "S3 Storage"
                        CreationTime = Get-Date
                        Source = "Repository"
                        RepositoryName = $Repository.Name
                        AdditionalInfo = "Cannot analyze S3 repository directly. Use Veeam console to manually check for orphaned backups."
                    }
                    
                    $orphanedData += $orphanObject
                }
            }
            catch {
                Write-Host "    Error processing backup $($backup.Name): $_" -ForegroundColor DarkGray
            }
        }
        
        return $orphanedData
    }
    catch {
        Write-Error "Error analyzing repository $($Repository.Name): $_"
        return $null
    }
}

# Main script execution
$totalOrphanedData = @()
$foundData = $false

# Analyze backup copy jobs if selected
if ($AnalysisMode -eq "Jobs" -or $AnalysisMode -eq "Both") {
    Write-Host "`nAnalyzing S3 backup copy jobs..." -ForegroundColor Cyan
    
    # Get S3 backup copy jobs
    $s3BackupCopyJobs = Get-VeeamS3BackupCopyJobs -JobName $JobName
    
    if ($s3BackupCopyJobs -and $s3BackupCopyJobs.Count -gt 0) {
        Write-Host "Found $($s3BackupCopyJobs.Count) S3 backup copy job(s)" -ForegroundColor Green
        $foundData = $true
        
        # Process each job
        foreach ($job in $s3BackupCopyJobs) {
            $orphanedData = Get-OrphanedBackupData -BackupCopyJob $job
            
            if ($orphanedData) {
                $totalOrphanedData += $orphanedData
                
                # Display results for current job
                $jobTotal = ($orphanedData | Measure-Object -Property FileSizeBytes -Sum).Sum / 1GB
                Write-Host "  Found $($orphanedData.Count) orphaned files in job '$($job.Name)' (Total: $([Math]::Round($jobTotal, 2)) GB)" -ForegroundColor Yellow
                
                if ($DetailedReport) {
                    $orphanedData | Format-Table -AutoSize JobName, BackupName, FileName, FileSize, CreationTime
                }
            }
            else {
                Write-Host "  No orphaned data found in job '$($job.Name)'" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "No S3 backup copy jobs found." -ForegroundColor Yellow
    }
}

# Analyze S3 repositories directly if selected
if ($AnalysisMode -eq "Repositories" -or $AnalysisMode -eq "Both") {
    Write-Host "`nAnalyzing S3 repositories directly..." -ForegroundColor Cyan
    
    # Get S3 repositories
    $s3Repositories = Get-VeeamS3Repositories -RepositoryName $RepositoryName
    
    if ($s3Repositories -and $s3Repositories.Count -gt 0) {
        Write-Host "Found $($s3Repositories.Count) S3 repositories" -ForegroundColor Green
        $foundData = $true
        
        # Process each repository
        foreach ($repo in $s3Repositories) {
            $orphanedData = Get-OrphanedRepositoryData -Repository $repo
            
            if ($orphanedData) {
                $totalOrphanedData += $orphanedData
                
                # Display results for current repository
                $repoTotal = ($orphanedData | Measure-Object -Property FileSizeBytes -Sum).Sum / 1GB
                Write-Host "  Found $($orphanedData.Count) orphaned files in repository '$($repo.Name)' (Total: $([Math]::Round($repoTotal, 2)) GB)" -ForegroundColor Yellow
                
                if ($DetailedReport) {
                    $orphanedData | Format-Table -AutoSize RepositoryName, BackupName, FileName, FileSize, CreationTime
                }
            }
            else {
                Write-Host "  No orphaned data found in repository '$($repo.Name)'" -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host "No S3 repositories found." -ForegroundColor Yellow
    }
}

if (-not $foundData) {
    Write-Host "`nNo S3 backup copy jobs or repositories found. Please check your configuration." -ForegroundColor Yellow
    Disconnect-VBRServer
    exit
}

# Summary
if ($totalOrphanedData.Count -gt 0) {
    $totalSize = ($totalOrphanedData | Measure-Object -Property FileSizeBytes -Sum).Sum / 1GB
    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "Found $($totalOrphanedData.Count) orphaned files across all S3 backup sources" -ForegroundColor Yellow
    Write-Host "Total orphaned data size: $([Math]::Round($totalSize, 2)) GB" -ForegroundColor Yellow
    
    # Export to CSV if requested
    if ($ExportCSV) {
        $totalOrphanedData | Export-Csv -Path $CSVPath -NoTypeInformation
        Write-Host "Results exported to CSV file: $CSVPath" -ForegroundColor Green
    }
}
else {
    Write-Host "`nNo orphaned backup data found." -ForegroundColor Green
}

# Disconnect from VBR Server
Disconnect-VBRServer
Write-Host "Script completed successfully." -ForegroundColor Green 