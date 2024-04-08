## ** VARIALBES THAT ARE REQUIRED. SET IN INTERACTIVE FOR FROM RMM ** 
### $Username
### $Domain
### $Password
### $downloadURL

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-autoadmin-logon.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $Username = Read-Host "Please enter the administrator username to auto login"
        $Domain = Read-Host "Please enter the administrator user domain"
        $Password = Read-Host "Please enter the password"
        $downloadURL = Read-Host "Please enter the download url"

        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }


    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else { 
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
        
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
        
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }   


    
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Username: $Username"
Write-Host "Domain: $Domain"
Write-Host "Password: ***REDACTED***"
Write-Host "Download URL: $downloadURL"

$targetDir = "$ENV:PROGRAMDATA\Sysinternals\Autologon"

# Create the target directory if it doesn't already exist
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir
}

# Specify the path of the downloaded ZIP file
$zipFile = Join-Path -Path $targetDir -ChildPath "AutoLogon.zip"

# Download the ZIP file
Invoke-WebRequest -Uri $downloadURL -OutFile $zipFile

# Extract the ZIP file
Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force

# Optionally, remove the ZIP file after extraction
Remove-Item -Path $zipFile

Write-Host "AutoLogon has been downloaded and extracted to: $targetDir"

& "$($targetDir)\Autologon.exe $($username) $($domain) $($password)" | Write-Host

Stop-Transcript
