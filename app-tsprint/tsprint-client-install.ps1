# --- Quick TSPrint Client install via BITS ---
$Url        = 'https://www.terminalworks.com/downloads/tsprint/TSPrint_client.exe'
$Installer  = "$env:TEMP\TSPrint_client.exe"
$SilentArgs = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'

Start-BitsTransfer -Source $Url -Destination $Installer          # download with BITS
Start-Process      -FilePath $Installer -ArgumentList $SilentArgs -Wait
Remove-Item        -Path $Installer -Force                       # tidy up
