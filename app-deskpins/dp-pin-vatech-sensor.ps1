# Check if DeskPins is already installed
$packageId = "EliasFotinis.DeskPins"
$installed = winget list --id $packageId

if ($installed -eq $null) {
    Write-Host "$packageId is not installed. Installing now..."
    
    # Install DeskPins using winget
    winget install -e --id $packageId --silent
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$packageId has been successfully installed."
    } else {
        Write-Host "Failed to install $packageId."
    }
} else {
    Write-Host "$packageid is already installed."
}
