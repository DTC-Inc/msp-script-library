# Set this variable:
#   $true  => Disable the shutdown option from the Windows UI
#   $false => Enable (restore) the shutdown option in the Windows UI
$DisableShutdownUI = $true  # Change to $false to re-enable the shutdown option

# Define the registry path for Explorer policies
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"

if ($DisableShutdownUI) {
    # Disable Shutdown UI:
    # Create the registry key if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Name "Explorer" -Force | Out-Null
    }
    # Set the NoClose value to disable the shutdown/restart options in the UI
    Set-ItemProperty -Path $regPath -Name "NoClose" -Value 1 -Type DWord
    Write-Host "Shutdown option from the Windows UI has been disabled."
}
else {
    # Enable Shutdown UI:
    if (Test-Path $regPath) {
        # If the "NoClose" property exists, remove it
        if (Get-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue
            Write-Host "Shutdown option from the Windows UI has been enabled."
        }
        else {
            Write-Host "No shutdown disabling registry entry found. Shutdown option is already enabled."
        }
    }
    else {
        Write-Host "Registry key not found. Shutdown option should be enabled by default."
    }
}

Write-Host "Note: You may need to log off or restart Explorer for the changes to take effect."
