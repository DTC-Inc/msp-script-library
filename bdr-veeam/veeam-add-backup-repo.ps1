## Please note this script can only support the following backup repository types ##
# S3 Compatible & Local. Both are forced.

# ===========================================
# PowerShell 7 x64 Check, Install, and Bootstrap
# ===========================================

# MUST use x64 path - Veeam modules are 64-bit only
$ps7Path = "C:\Program Files\PowerShell\7\pwsh.exe"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    
    Write-Host "Running in PowerShell $($PSVersionTable.PSVersion.Major) - checking for PS7 x64..."
    
    # Check if PS7 x64 is installed
    if (-not (Test-Path $ps7Path)) {
        Write-Host "PowerShell 7 x64 not found. Installing..."
        
        try {
            $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/PowerShell-7.4.7-win-x64.msi"
            $msiPath = "$env:TEMP\PS7-x64.msi"
            
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
            
            Write-Host "Downloaded PS7 installer. Running silent install..."
            Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn REGISTER_MANIFEST=1" -Wait -NoNewWindow
            
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            
            if (-not (Test-Path $ps7Path)) {
                Write-Error "PowerShell 7 x64 installation failed"
                exit 1
            }
            Write-Host "PowerShell 7 x64 installed successfully"
        }
        catch {
            Write-Error "Failed to download/install PowerShell 7: $_"
            exit 1
        }
    }
    
    # ===========================================
    # Capture NinjaRMM variables to pass to PS7
    # ===========================================
    Write-Host "Capturing RMM variables for PS7 session..."
    
    # Build parameter string for PS7 relaunch
    $scriptBlock = @"
`$repositoryType = '$repositoryType'
`$moveBackups = '$moveBackups'
`$description = '$description'
`$immutabilityPeriod = '$immutabilityPeriod'
`$accessKey = '$accessKey'
`$secretKey = '$secretKey'
`$endpoint = '$endpoint'
`$regionId = '$regionId'
`$bucketName = '$bucketName'
`$driveLetters = '$driveLetters'
`$folderName = '$folderName'
`$moveListedBackups = '$moveListedBackups'

"@

    # Read main script content (everything after the marker)
    $scriptContent = Get-Content -Path $MyInvocation.MyCommand.Path -Raw
    $marker = "# === MAIN SCRIPT START ==="
    $markerIndex = $scriptContent.IndexOf($marker)
    
    if ($markerIndex -gt 0) {
        $mainScript = $scriptContent.Substring($markerIndex + $marker.Length)
        $fullScript = $scriptBlock + $mainScript
        
        # Write temp script and execute in PS7 x64
        $tempScript = "$env:TEMP\veeam-repo-ps7-$(Get-Random).ps1"
        $fullScript | Out-File -FilePath $tempScript -Encoding UTF8 -Force
        
        Write-Host "Relaunching in PowerShell 7 x64: $ps7Path"
        & $ps7Path -NoProfile -ExecutionPolicy Bypass -File $tempScript
        $exitCode = $LASTEXITCODE
        
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        exit $exitCode
    }
    else {
        Write-Error "Could not find main script marker"
        exit 1
    }
}

# === MAIN SCRIPT START ===
# ===========================================
# Running in PS7 x64 - Execute Veeam commands
# ===========================================

Write-Host "Running in PowerShell $($PSVersionTable.PSVersion) x64 - Proceeding with Veeam configuration"

Start-Transcript -Path $env:WINDIR\logs\veeam-add-backup-repo-ps7.log -Force

Write-Host "The variables are now set."
Write-Host "Repository type: $repositoryType"
Write-Host "Move backups: $moveBackups"
Write-Host "Description: $description"
Write-Host "Immutability period: $immutabilityPeriod"
Write-Host "Access key: $accessKey"
Write-Host "Secret key: **redacted for sensitivity**"
Write-Host "S3 Endpoint: $endpoint"
Write-Host "S3 Region ID: $regionId"
Write-Host "S3 Bucket Name: $bucketName"
Write-Host "Automatic volume letter to create WinLocal repo: "
Write-Host "Drive letters to create WinLocal Repos: $driveLetters"

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

if ($repositoryType -eq 1 -Or $repositoryType -eq 3) {
    Write-Host "Creating S3 Repository: S3 $folderName"

    # Add the S3 Account
    $account = Add-VBRAmazonAccount -AccessKey $accessKey -SecretKey $secretKey -Description "$description $bucketName"

    # Create the S3 repository
    $connect = Connect-VBRAmazonS3CompatibleService -Account $account -CustomRegionId $regionId -ServicePoint $endpoint
    $bucket = Get-VBRAmazonS3Bucket -Connection $connect -Name $bucketName
    $folder = New-VBRAmazonS3Folder -Name $folderName -Connection $connect -Bucket $bucket

    # Get Veeam server version from DLL and convert to [version]
    $veeamVersion = [version](Get-Item 'C:\Program Files\Veeam\Backup and Replication\Backup\Packages\VeeamDeploymentDll.dll').VersionInfo.ProductVersion
    $requiredVersion = [version]"12.3.1.1139"

    # Conditionally run the appropriate command based on version
    if ($veeamVersion -ge $requiredVersion) {
        Add-VBRAmazonS3CompatibleRepository `
            -AmazonS3Folder $folder `
            -Connection $connect `
            -Name "S3 $folderName" `
            -EnableBackupImmutability `
            -ImmutabilityPeriod $immutabilityPeriod `
            -Description "$description $bucketName" `
            -EnableBucketAutoProvision:$false
    } else {
        Add-VBRAmazonS3CompatibleRepository `
            -AmazonS3Folder $folder `
            -Connection $connect `
            -Name "S3 $folderName" `
            -EnableBackupImmutability `
            -ImmutabilityPeriod $immutabilityPeriod `
            -Description "$description $bucketName"
    }

    # Display the added repository details
    $repository
}

if ($repositoryType -eq 2 -Or $repositoryType -eq 3){
    Write-Host "Creating local repository Local $folderName"
    # Get all logical drives on the system
    $drives = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }

    # Find the drive with the largest total capacity
    if ($drives.Count -gt 1){ 
        $filteredDrives = $drives | Where-Object { $_.DeviceId -ne 'C:' }
    } else {
        $filteredDrives = $drives
    }

    # Create the local repository
    $filteredDrives | ForEach-Object { 
        $repositoryPath = Join-Path -Path $_.DeviceID -ChildPath "\veeam\$folderName"
        $repositoryName = "Local $folderName"
        Write-Host "Repository name: $repositoryName"
        Write-Host "Repository path: $repositoryPath"
        $repository = Add-VBRBackupRepository -Type WinLocal -Name "$repositoryName" -Folder $repositoryPath -Description "$description"
        # Display the added repository details
        $repository
        $localRepository = $repository
        Start-Sleep -Seconds 1
    }
}

# Move all local backups
if ($moveBackups -eq 1){
    $backups = Get-VBRBackup | Where -Property TypeToString -ne "Backup Copy"
    $localRepository = Get-VBRBackupRepository | Where -Property Name -like "Local*" | Select -First 1 | Select -Expand Name
    
    Write-Host "moving all backups to $localRepository"
    $backups | ForEach-Object {
        Move-VBRBackup -Repository $localRepository -Backup $_ -RunAsync -Force
    }
}

# Move listed backups
if ($moveListedBackups){ 
    Write-Host "Moving $moveListedBackups to $localRepository."

    $moveListedBackups | ForEach-Object {
        Move-VBRBackup -Repository $localRepository -Backup $_ -RunAsync
    }
}

Stop-Transcript
