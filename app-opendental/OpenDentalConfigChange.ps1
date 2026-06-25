## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description    / $env:description    - Ticket # and/or initials, used as the job description
## $rmmScriptPath  / $env:rmmScriptPath  - Optional log directory base provided by the RMM
## $middleTierURI  / $env:middleTierURI  - Middle Tier URI; if set, configures a Middle Tier connection
## $serverFQDN     / $env:serverFQDN     - Database server FQDN for a direct database connection
## $passwordHash   / $env:passwordHash   - MySQL password hash for the direct database connection

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$rmmScriptPath = $env:rmmScriptPath,
    [string]$middleTierURI = $env:middleTierURI,
    [string]$serverFQDN    = $env:serverFQDN,
    [string]$passwordHash  = $env:passwordHash
)

$scriptLogName = "opendental-server-change.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied (e.g. an automated RMM run).
if (-not $description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if ($rmmScriptPath -ne $null) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"

} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"

}

Start-Transcript -Path $logPath

Write-Host "Description: $description"
Write-Host "Log path: $logPath"

# Define the path to the configuration file
$configFilePath = "C:\Program Files (x86)\Open Dental\FreeDentalConfig.xml"

# OpenDental FreeDentalConfig.xml xml object
$xml = New-Object System.Xml.XmlDocument
$root = $xml.CreateElement("ConnectionSettings")
$xml.AppendChild($root)

# Direct database config
$node1DatabaseConnection = $xml.CreateElement("DatabaseConnection")

# Application server config
$node2ServerConnection = $xml.CreateElement.("ServerConnection")

if ($middleTierURI) {
    # Middle Tier config
    $node2ServerConnection.URI = "$middleTierURI"
    $node2ServerConnection.UsingEcw = "False"
    $root.DatabaseType = "MySQL"
    $root.UseDynamicMode = "False"
    # $root.RemoveChild(DatabaseConnection)

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
