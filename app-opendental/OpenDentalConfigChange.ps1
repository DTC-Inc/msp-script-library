# Getting input from user if not running from RMM else set variables from RMM.

$scriptLogName = "opendental-server-change.log"

if ($rmm -ne 1) {
    $validInput = 0
    # Checking for valid input.
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"
        if ($description) {
            $validInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $logPath = "$env:WINDIR\logs\$scriptLogName"

} else { 
    # Store the logs in the rmmScriptPath
    if ($rmmScriptPath -ne $null) {
        $logPath = "$rmmScriptPath\logs\$scriptLogName"
        
    } else {
        $logPath = "$env:WINDIR\logs\$scriptLogName"
        
    }

    if ($description -eq $null) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $description = "No description"
    }   


    
}

Start-Transcript -Path $logPath

Write-Host "Description: $description"
Write-Host "Log path: $logPath"
Write-Host "RMM: $rmm"

# Define the path to the configuration file
$configFilePath = "C:\Program Files (x86)\Open Dental\FreeDentalConfig.xml"

# Load the XML content from the file
[xml]$configXml = Get-Content $configFilePath

if ($middleTierURI) {
    # Middle Tier config
    $configXml.ConnectionSettings.ServerConnection.URI = "$middleTierURI"
    $configXml.ConnectionSettings.ServerConnection.UsingEcw = "False"
    $configXml.ConnectionSettings.DatabaseType = "MySQL"
    $configXml.ConnectionSettings.UseDynamicMode = "False"
    $configXml.ConnectionSettings.RemoveChild(DatabaseConnection)
    
} else {
    # Modify the fields under <ConnectionSettings>
    $configXml.ConnectionSettings.DatabaseConnection.ComputerName = "$serverFQDN"
    $configXml.ConnectionSettings.DatabaseConnection.Database = "opendental"
    $configXml.ConnectionSettings.DatabaseConnection.User = "root"
    $configXml.ConnectionSettings.DatabaseConnection.Password = ""
    $configXml.ConnectionSettings.DatabaseConnection.MySQLPassHash = "$passwordHash"
    $configXml.ConnectionSettings.DatabaseConnection.NoShowOnStartup = "True"
    
    # Modify other fields
    $configXml.ConnectionSettings.DatabaseType = "SqlServer"
    $configXml.ConnectionSettings.UseDynamicMode = "True"
    
}



# Save the modified XML back to the file
$configXml.Save($configFilePath)

Write-Host "Configuration file updated successfully."


Stop-Transcript
