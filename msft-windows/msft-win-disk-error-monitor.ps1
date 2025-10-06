# Keeps output simple for NinjaOne to parse (ErrorDetected=0/1), with optional counts per Event ID and SMART status.

# Expands coverage to catch driver-specific resets/timeouts that don’t always appear under Source=Disk.

# Safe to run on endpoints without SMART WMI class; it just skips that check.



param(
    [int]$Minutes = 30
)

$start = (Get-Date).AddMinutes(-$Minutes)

# Common disk / storage error IDs
# 7,11,29,51,153 (Disk) plus 129 (reset), 157 (surprise removal), 140 (flush failure)
$eventIds   = 7,11,29,51,129,140,153,157

# Providers that commonly log disk I/O issues on different chipsets/drivers
$providers  = @(
    'Disk',      # classic disk errors incl. 7/11/29/51/153
    'Ntfs',      # filesystem-level I/O issues (e.g., 140)
    'storahci',  # MS AHCI
    'iaStorA',   # Intel RST
    'iaStorV',   # older Intel
    'stornvme',  # Microsoft NVMe
    'nvme',      # vendor NVMe providers sometimes use this name
    'StorPort',  # storport miniport layer (resets/timeouts)
    'partmgr'    # partition manager (removals/changes)
)

$allEvents = @()

foreach ($p in $providers) {
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = $p
            Id           = $eventIds
            StartTime    = $start
        } -ErrorAction SilentlyContinue
        if ($ev) { $allEvents += $ev }
    } catch {
        # ignore provider-specific lookup failures
    }
}

# SMART: Predictive failure (true means the drive thinks it's failing)
$smartFailure = $false
try {
    # MS storage driver SMART (WMI)
    $smart = Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
    if ($smart) {
        $smartFailure = ($smart | Where-Object { $_.PredictFailure -eq $true }).Count -gt 0
    }
} catch {
    # ignore if class not available
}

$hasEvents = ($allEvents.Count -gt 0)

if ($hasEvents -or $smartFailure) {
    $summary = @()
    if ($hasEvents) {
        $byId = $allEvents | Group-Object Id | Sort-Object Name
        $summary += ($byId | ForEach-Object { "ID$($_.Name)=$($_.Count)" })
    }
    if ($smartFailure) { $summary += "SMART=PredictedFailure" }

    Write-Output ("ErrorDetected=1; " + ($summary -join '; '))
    exit 1
} else {
    Write-Output "ErrorDetected=0"
    exit 0
} catch {
    Write-Host "Error occurred in msft-win-disk-error-monitor.ps1: $($_.Exception.Message)"
    $ErrorDetected = 1
}

# If ErrorDetected is 1, run the second script
if ($ErrorDetected -eq 1) {
    Write-Host "Error detected. Running crystalmarkdiskupdate.ps1..."
    try {
# --- Start of DownloadCrystalDisk.ps1 ---
# URL of the compressed file to download
Write-Host "URL: '$downloadurl'"
$url = $downloadURL
# Location where you want to save the downloaded file
$downloadLocation = "C:\CrystalDiskInfo\CrystalDiskInfo9_6_3.zip"
# Location where you want to extract the contents
$extractLocation = "C:\CrystalDiskInfo"

# Create the CrystalDiskInfo directory if it doesn't exist
if (-Not (Test-Path $extractLocation)) {
    New-Item -Path $extractLocation -ItemType Directory | Out-Null
    Write-Host "Created directory: $extractLocation"
}

# Check if the file already exists
if (-Not (Test-Path $downloadLocation)) {
    Write-Host "File does not exist. Downloading now..."
    Invoke-WebRequest -Uri $url -OutFile $downloadLocation
} else {
    Write-Host "File already exists. Skipping download."
}

# Proceed if the file exists
if (Test-Path $downloadLocation) {
    # Extract the contents to the specified location
    Expand-Archive -Path $downloadLocation -DestinationPath $extractLocation -Force
    Write-Host "Extraction completed successfully."
} else {
    Write-Host "Download failed or file does not exist. Please check the URL and try again."
}

# --- Start of crystaldisk.ps1 ---
$cdiskinfo = "C:\CrystalDiskInfo"

# Make sure the directory exists again before running the executable
if (-Not (Test-Path $cdiskinfo)) {
    Write-Host "Directory $cdiskinfo does not exist. Aborting."
    exit
}

$outputFile = "$cdiskinfo\DiskInfo.txt"

# Delete old output file to ensure we get fresh data
if (Test-Path $outputFile) {
    Remove-Item $outputFile -Force
    Write-Host "Removed old output file."
}

# Run CrystalDiskInfo and wait for the process to complete
Write-Host "Running CrystalDiskInfo..."
$process = Start-Process -FilePath "$cdiskinfo\DiskInfo64.exe" -ArgumentList "/CopyExit" -PassThru -Wait

# Wait a bit longer to ensure file is written
Start-Sleep -Seconds 2

# Wait for the output file to exist and have content
$timeout = 30
$elapsed = 0
while (-Not (Test-Path $outputFile) -or (Get-Item $outputFile).Length -eq 0) {
    if ($elapsed -ge $timeout) {
        Write-Host "ERROR: Timeout waiting for CrystalDiskInfo output file."
        exit 1
    }
    Start-Sleep -Seconds 1
    $elapsed++
}

Write-Host "Output file created successfully."

$s = Get-Content $outputFile

$models    = ($s | Select-String "           Model : ")    | ForEach-Object { $_.Line -replace "           Model : ", "" }
$firmwares = ($s | Select-String "        Firmware : ")    | ForEach-Object { $_.Line -replace "        Firmware : ", "" }
$healths   = ($s | Select-String "   Health Status : ")    | ForEach-Object { $_.Line -replace "   Health Status : ", "" }
$dletters  = ($s | Select-String "    Drive Letter : ")    | ForEach-Object { $_.Line -replace "    Drive Letter : ", "" }
$temps     = ($s | Select-String "     Temperature : ")    | ForEach-Object { $_.Line -replace "     Temperature : ", "" }
$feats     = ($s | Select-String "        Features : ")    | ForEach-Object { $_.Line -replace "        Features : ", "" }

$Drives = for ($i = 0; $i -lt $models.Count; $i++) {
    [PSCustomObject]@{
        "Model"    = $models
        "Firmware" = $firmwares
        "Health"   = $healths
        "Letter"   = $dletters
        "Temp"     = $temps
        "Features" = $feats
    }
}

$Drives
    } catch {
        Write-Host "Error occurred in crystalmarkdiskupdate.ps1: $($_.Exception.Message)"
    }
} else {
    Write-Host "No errors detected. Skipping crystalmarkdiskupdate.ps1."
}


