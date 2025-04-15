# --- Start of DownloadCrystalDisk.ps1 ---
# URL of the compressed file to download
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

# Run CrystalDiskInfo and capture output
& "$cdiskinfo\DiskInfo64.exe" /CopyExit

# Ensure the output file exists before attempting to read it
$outputFile = "$cdiskinfo\DiskInfo.txt"
if (-Not (Test-Path $outputFile)) {
    New-Item $outputFile -ItemType File -Force | Out-Null
    Write-Host "Created output file: $outputFile"
}

$s = Get-Content $outputFile
$models = ($s | Select-String "           Model : ") -replace "           Model : ", ""
$firmwares = ($s | Select-String "        Firmware : ") -replace "        Firmware : ", ""
$healths = ($s | Select-String "   Health Status : ") -replace "   Health Status : ", ""
$dletters = ($s | Select-String "    Drive Letter : ") -replace "    Drive Letter : ", ""
$temps = ($s | Select-String "     Temperature : ") -replace "     Temperature : ", ""
$feats = ($s | Select-String "        Features : ") -replace "        Features : ", ""

$Drives = for ($i = 0; $i -lt $models.Count; $i++) {
    [PSCustomObject]@{
        "Model"    = $models[$i]
        "Firmware" = $firmwares[$i]
        "Health"   = $healths[$i]
        "Letter"   = $dletters[$i]
        "Temp"     = $temps[$i]
        "Features" = $feats[$i]
    }
}
$Drives
