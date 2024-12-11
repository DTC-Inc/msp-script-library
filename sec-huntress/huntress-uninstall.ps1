$HuntressDir = "C:\Program Files\Huntress"
$UninstallExe = "$HuntressDir\Uninstall.exe"
$HuntressAgent = "$HuntressDir\HuntressAgent.exe"
$HuntressUpdater = "$HuntressDir\HuntressUpdater.exe"

# Check if Uninstall.exe exists
if (Test-Path $UninstallExe) {
    Write-Output "Uninstall.exe found. Running silent uninstall..."
    Start-Process -FilePath $UninstallExe -ArgumentList "/S" -NoNewWindow -Wait
} else {
    Write-Output "Uninstall.exe not found. Running fallback commands..."

    # Attempt to uninstall using HuntressAgent.exe
    if (Test-Path $HuntressAgent) {
        Write-Output "Running HuntressAgent.exe uninstall..."
        Start-Process -FilePath $HuntressAgent -ArgumentList "uninstall" -NoNewWindow -Wait
    }

    # Attempt to uninstall using HuntressUpdater.exe
    if (Test-Path $HuntressUpdater) {
        Write-Output "Running HuntressUpdater.exe uninstall..."
        Start-Process -FilePath $HuntressUpdater -ArgumentList "uninstall" -NoNewWindow -Wait
    }

    # Remove Huntress directory
    if (Test-Path $HuntressDir) {
        Write-Output "Removing Huntress directory..."
        Remove-Item -Path $HuntressDir -Recurse -Force
    }

    # Notify the user to wait and pause for input
    Write-Output "Please wait 10 seconds and press any key."
    Start-Sleep -Seconds 10
    Pause

    # Delete registry key
    Write-Output "Removing Huntress Labs registry key..."
    reg delete "HKLM\SOFTWARE\Huntress Labs" /f
}

Write-Output "Uninstallation process completed."
