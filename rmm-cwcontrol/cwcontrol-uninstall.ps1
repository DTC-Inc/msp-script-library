## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description   / $env:description   - Ticket # or initials for audit trail (default: "No description")
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

$scriptLogName = "cw-control-uninstall.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# The body reads $description and $rmmScriptPath by bare name, so the resolved parameter
# values are used directly. Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

Write-Output $description
Write-Output $rmmScriptPath

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Start-Transcript -Path $logPath

# Define the service name pattern
$ServicePattern = "*ScreenConnect*"

# Get services matching the pattern
$Services = Get-Service | Where-Object { $_.Name -like $ServicePattern }

if ($Services) {
    foreach ($Service in $Services) {
        Write-Output "Uninstalling $($Service.Name)..."
        try {
            # Uninstall the application associated with the service
            # Check if any instances are installed

            $installed = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*

            # Remove the application if it is installed

            if ($installed) {
                Write-Output "ConnectWise Control (ScreenConnect) is installed so we're uninstalling."
                $installed | ForEach-Object {
                    try {
                        $_.Uninstall()
                        Start-Sleep -Seconds 10
                    } catch {
                           Write-Output "An error has occured that coult not be resolved."

                    }    
                }
            }

            # Check if application is still installed. 
            $installCheck = Get-WmiObject -Class Win32_Product | Where -Property Name -like *ScreenConnect*
            if ($installCheck) {
                # Write-Output "Uninstall failed."
                Write-Output "Uninstall failed for $($Service.Name). Attempting force deletion..."
                # Attempt force deletion of the service
                $Service | Stop-Service -Force -ErrorAction SilentlyContinue
                $ServiceDeleteResult = sc.exe delete "$($Service.Name)" | Write-Output
                Write-Output "Service delete output: $ServiceDeleteResult"
                # $ServiceDeleteResult | Wait-Process -Timeout 10
                $IsServiceDeleted = Get-Service | Where-Object { $_.Name -eq $Service.Name } | Select $_.Name
                Write-Output "Checking if service $($Service.Name) exists. $IsServiceDeleted"
                if (!($IsServiceDeleted)) {
                    Write-Output "Service $($Service.Name) forcibly deleted."
                    Exit 0
                } else {
                    Write-Output "Service $($Service.Name) delete failed."
                    Exit 1
                }
            }
        } catch {
            Write-Output "Error occurred while uninstalling $($Service.Name): $_"
            Exit 1
        }
    }
} else {
    Write-Output "No services found matching the pattern $ServicePattern"
    Exit 0
}

Stop-Transcript
