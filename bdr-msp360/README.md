# MSP360 Backup Agent Installation and Configuration

This directory contains PowerShell scripts for installing and configuring MSP360 backup agents.

## Scripts

### msp360-staging-install-and-configure.ps1

A comprehensive script that:
- Checks if MSP360 agent is already installed and healthy
- Attempts to restart stopped services before reinstalling
- Downloads and installs the MSP360 backup agent (only if needed)
- Configures the agent with the staging account (`staging@dtctooday.com`)
- Uses existing storage accounts configured in MSP360 (prefers "Staging Storage")
- Creates an image-based backup plan that runs nightly at 12:00 AM
- Sets up incremental backups to the Backblaze cloud storage

### run-msp360-staging-install.bat

A convenient batch file wrapper that:
- Automatically runs the PowerShell script with execution policy bypass
- Provides user-friendly prompts and status messages
- Eliminates the need to manually type the PowerShell command

## Requirements

- Windows PowerShell 5.1 or PowerShell Core 6+
- Administrator privileges
- Internet connection for downloading the MSP360 agent
- Valid MSP360 account credentials

**Note**: This script must be run with `-ExecutionPolicy Bypass`

## Usage

### Interactive Mode (Manual Execution)

**Option 1: Use the Batch File (Easiest)**
```batch
# Double-click or run from command prompt
run-msp360-staging-install.bat
```

**Option 2: PowerShell Command**
```powershell
# Run with execution policy bypass (required)
powershell.exe -ExecutionPolicy Bypass -File .\msp360-staging-install-and-configure.ps1
```

The script will prompt for:
- Ticket number or initials for logging
- MSP360 account email (defaults to staging@dtctooday.com)
- MSP360 account password (secure input)
- Backup plan name (defaults to "Image Backup Plan")
- Service names (defaults to DTCBSure services, option for custom)
- Storage account selection (if "Staging Storage" doesn't exist)

### RMM Mode (Automated Execution)
Set the following variables in your RMM before execution:
```powershell
$RMM = 1
$MSPAccountEmail = "staging@dtctooday.com"  # Optional, defaults to staging account
$MSPAccountPassword = "YourPasswordHere"    # Required
$BackupPlanName = "Image Backup Plan"       # Optional, defaults to "Image Backup Plan"
$Description = "Automated MSP360 Setup"     # Optional

# Optional: Custom service names (defaults to DTCBSure services)
$ServiceNames = @("Your Service Name 1", "Your Service Name 2")
```

**Note**: Authentication uses MBS user credentials with SSL enabled by default.

**Important**: Configure your RMM to run the script with `-ExecutionPolicy Bypass`

**Note**: If any required variables are not provided by the RMM, the script will prompt for them interactively. This ensures the script can always run successfully even if some variables are missing from the RMM configuration.

## Smart Installation Logic

The script includes intelligent installation detection:

1. **Health Check**: First checks if MSP360 agent is already installed and running
2. **Service Configuration**: Allows custom service names or uses DTCBSure defaults
3. **Service Recovery**: If configured services are stopped, attempts to restart them before reinstalling
4. **Skip Installation**: If agent and all configured services are healthy, skips unnecessary reinstallation
5. **Module Detection**: Checks if PowerShell module is already loaded before importing

This makes the script safe to run multiple times and much faster on systems where MSP360 is already working properly.

## Configuration Details

- **Storage Account**: "Staging Storage" (Backblaze - Staging West US)
- **Bucket**: msp360-staging
- **Schedule**: Daily at 12:00 AM
- **Backup Type**: Image-based backup of all volumes
- **Compression**: Enabled
- **Incremental Backups**: Yes (after initial full backup)

## Logging

Logs are stored in:
- **Interactive Mode**: `C:\Windows\logs\MSP360-Staging-Install-Configure.log`
- **RMM Mode**: `{RMMScriptPath}\logs\MSP360-Staging-Install-Configure.log` or Windows logs if RMM path not available

## Troubleshooting

1. **Installation Fails**: Ensure you have administrator privileges and internet connectivity

2. **Service Restart Fails**: The script will attempt to restart stopped backup services automatically. If this fails:
   - Check Windows Event Logs for service-related errors
   - Ensure no backup service processes are hung (check Task Manager)  
   - May require manual service restart or reboot
   - Default services: "DTCBSure Cloud Backup Service" and "DTCBSure Cloud Backup Service Remote Management"
   - Custom service names can be configured during script execution or via RMM variables

3. **Account Login Fails**: Verify the MSP360 account credentials are correct

4. **"MBS user not specified" Error**: This is a known non-fatal error in some MSP360 module versions:
   - The script will show this as a warning but continue execution
   - Login often succeeds despite this error message  
   - Alternative verification methods are used to confirm login status

5. **Storage Account Not Found**: The script will handle this automatically by:
   - Showing available storage accounts configured in MSP360
   - Offering to use an existing account
   - In RMM mode, automatically using the first available storage account

6. **No Storage Accounts Available**: 
   - Configure at least one storage account in the MSP360 console first
   - Storage accounts must be set up through the MSP360 web interface
   - Ensure the storage account is properly tested and accessible

7. **Backup Plan Creation Fails**: Check that the storage account is properly configured and accessible

8. **Module Import Fails**: If the MSP360 module fails to import, ensure the agent is properly installed

## Notes

- The script uses the MSP360 PowerShell module which is automatically installed during the agent installation
- The backup plan will include all volumes on the system
- Bad sectors are ignored during backup to prevent failures on drives with minor issues
- The script includes comprehensive error handling and logging for troubleshooting 