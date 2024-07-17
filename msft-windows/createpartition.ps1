# Create a string containing the diskpart commands
$diskpartScript = @"
create partition primary id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
format quick fs=ntfs label="Windows RE tools"
"@

# Save the string to a temporary script file
$tempScriptFile = "$env:TEMP\diskpart_script.txt"
$diskpartScript | Out-File -FilePath $tempScriptFile -Encoding ASCII

# Run diskpart with the script file
Start-Process -FilePath "diskpart.exe" -ArgumentList "/s", $tempScriptFile -Wait

# Remove the temporary script file
Remove-Item -Path $tempScriptFile
