# MSP360 Staging Installation and Configuration Script

## Overview

The `msp360-staging-install-and-configure.ps1` script provides comprehensive MSP360 backup agent installation and configuration specifically designed for staging environments. This script uses a **hybrid approach** combining PowerShell cmdlets for account management and the CBB (CloudBerry Backup) executable for backup plan creation to avoid SSE (Server-Side Encryption) parameter restrictions.

## Key Features

### 🔧 **Intelligent Installation & Health Checking**
- Detects existing MSP360 installations and validates agent health
- Attempts service recovery before reinstalling
- Skips unnecessary operations when agent is already functional
- Safe to run multiple times (idempotent operation)

### 🔒 **Enhanced Backup Plan Creation**
- **CBB Executable Integration**: Uses CBB command-line to avoid PowerShell cmdlet SSE restrictions
- **Image-Based Backups**: System Required volumes with compression enabled
- **Forever Forward Incremental (FFI)**: Enabled with new backup format for maximum efficiency
- **AES256 Encryption**: Custom encryption password protection
- **7-Day Retention**: Automatic purge of versions older than 7 days

### 🏷️ **Smart Backup Prefix System**
- **Auto-Generated Prefix**: `{organization}-{site}-{computer}` format
- **DNS-Friendly Sanitization**: Removes special characters, converts spaces to hyphens
- **RMM Integration**: Uses `$OrganizationName` and `$SiteName` variables
- **Account-Level Setting**: Applied to all future backup plans automatically

### ✅ **Advanced Plan Validation**
- Detects existing backup plans by name
- Validates configuration (volumes, storage account, schedule)
- Removes and recreates plans with incorrect settings
- Comprehensive error handling with multiple fallback methods

### 🔕 **Minimal Notifications**
- **Email Notifications**: Disabled by default
- **Windows Event Logging**: Enabled for monitoring
- **Comprehensive Console Output**: Detailed progress and status information

## Script Flow

### Step 1: MSP360 Agent Health Check
- Checks for existing installation and service status
- Downloads and installs agent only if needed
- Validates agent readiness

### Step 2: Account Configuration & Backup Prefix
- Adds MSP360 user account with staging credentials
- Sets DNS-friendly backup prefix at account level
- Uses PowerShell cmdlets with SSL and fallback options

### Step 3: Storage Account Setup
- Validates "Staging Storage" account via CBB executable
- Uses fallback configuration if validation fails

### Step 4: Backup Plan Detection & Validation
- Searches for existing plans matching the target name
- Validates plan configuration against desired settings
- Removes incorrect plans and prepares for recreation

### Step 5: CBB-Based Backup Plan Creation
- Creates image backup plan using CBB executable
- Configures all advanced settings via command line
- Provides fallback to simplified configuration if needed

### Step 6: Configuration Summary
- Displays comprehensive setup details
- Shows all configured parameters and status

## Requirements

- **Windows PowerShell 5.1+** or PowerShell Core 6+
- **Administrator Privileges** (required for agent installation)
- **Internet Connection** (for agent download)
- **MSP360 Account Credentials** (staging account)
- **CBB Executable** (installed with MSP360 agent)

## Usage

### 🎯 **RMM Mode (Recommended)**

Configure these variables in your RMM platform:

```powershell
# Required Variables
$RMM = 1
$MSPAccountPassword = "YourStagingPassword"

# Optional Variables (with defaults)
$MSPAccountEmail = "staging@dtctooday.com"
$BackupPlanName = "Staging Job"
$OrganizationName = "YourOrganization"  # For backup prefix
$SiteName = "YourSite"                  # For backup prefix
$CBBPath = "C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe"
$Description = "Automated MSP360 Staging Setup"
```

**Execution:**
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\msp360-staging-install-and-configure.ps1
```

### 🖱️ **Interactive Mode**

**Option 1: Batch File (Easiest)**
```batch
run-msp360-staging-install.bat
```

**Option 2: Direct PowerShell**
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\msp360-staging-install-and-configure.ps1
```

The script will prompt for:
- MSP360 account credentials
- Organization and site names (for backup prefix)
- Backup plan name
- Custom CBB executable path (if needed)

## Configuration Details

### 📋 **Backup Plan Settings**
- **Plan Type**: Image-based backup (System Required volumes)
- **Schedule**: Daily at 12:00 AM (00:00)
- **Compression**: Enabled
- **Encryption**: AES256 with custom password
- **VSS**: System VSS enabled
- **New Backup Format**: Enabled (required for FFI)
- **Forever Forward Incremental**: Enabled
- **Retention**: 7-day automatic purge
- **Bad Sectors**: Ignored
- **Notifications**: Disabled
- **Event Logging**: Enabled

### 🏷️ **Backup Prefix Format**
```
{organization}-{site}-{computer}
```

**Example**: `acme-headquarters-ws001`

**Sanitization Rules**:
- Converts to lowercase
- Replaces spaces with hyphens
- Removes special characters except hyphens
- Ensures DNS/URL compatibility

### 🗄️ **Storage Configuration**
- **Account**: "Staging Storage"
- **Provider**: Backblaze B2
- **Bucket**: msp360-staging
- **Region**: West US

## CBB Command Structure

The script generates CBB commands like:
```bash
cbb.exe addBackupIBBPlan 
  -a "Staging Storage" 
  -n "Staging Job" 
  -r 
  -c yes 
  -useSystemVss yes 
  -ignoreBadSectors yes 
  -ea AES256 
  -ep "password" 
  -nbf 
  -ffi yes 
  -every day 
  -at 00:00 
  -purge 7d 
  -notification no 
  -winLog on
```

## Logging

### 📁 **Log Locations**
- **RMM Mode**: `{ScriptPath}\logs\MSP360-Staging-Install-Configure-{timestamp}.log`
- **Interactive Mode**: `C:\Windows\logs\MSP360-Staging-Install-Configure-{timestamp}.log`

### 📊 **Log Contents**
- Detailed execution steps
- Error messages and warnings
- Configuration validation results
- CBB command execution output
- Final configuration summary

## Troubleshooting

### ❌ **Common Issues**

#### **1. SSE Parameter Restrictions**
```
Error: Cannot execute the command. The -sse parameter usage is restricted by the service provider
```
**Solution**: Script automatically uses CBB executable instead of PowerShell cmdlets

#### **2. CBB Executable Not Found**
```
❌ CBB executable not found in standard locations
```
**Solutions**:
- Set `$CBBPath` RMM variable to correct path
- Ensure MSP360 agent is properly installed
- Check common installation paths manually

#### **3. Forever Forward Incremental Errors**
```
The specified parameter '-ffi' can be applied with the new backup format only
```
**Solution**: Script automatically includes `-nbf` (new backup format) flag

#### **4. Existing Plan Validation Issues**
```
❌ Existing backup plan has configuration issues
```
**Solution**: Script automatically removes and recreates plans with incorrect settings

#### **5. PowerShell Module Errors**
```
Could not check existing plans via PowerShell
```
**Solution**: Script falls back to CBB executable for plan detection

### 🔧 **Advanced Troubleshooting**

#### **Manual CBB Testing**
Test CBB executable manually:
```powershell
& "C:\Program Files\MSP360\MSP360 (CloudBerry) Backup\cbb.exe" list
& "C:\Program Files\MSP360\MSP360 (CloudBerry) Backup\cbb.exe" listStorageAccounts
```

#### **PowerShell Module Verification**
```powershell
Import-Module MSP360 -Force
Get-MBSBackupPlan
Get-MBSStorageAccount
```

#### **Service Status Check**
```powershell
Get-Service "*MSP360*" | Select-Object Name, Status
Get-Service "*CloudBerry*" | Select-Object Name, Status
```

## Security Considerations

### 🔐 **Password Handling**
- Uses `SecureString` for all password inputs
- Clears plain text passwords from memory immediately after use
- No passwords stored in logs or output

### 🛡️ **Execution Policy**
- Requires `-ExecutionPolicy Bypass` for RMM environments
- Script includes comprehensive input validation
- Administrative privileges required for agent operations

## Compatibility

### ✅ **Supported Environments**
- Windows Server 2016+
- Windows 10/11
- PowerShell 5.1+
- PowerShell Core 6+
- MSP360 Backup Agent 7.0+

### 🔄 **RMM Platform Integration**
- ConnectWise Automate
- ConnectWise Control
- NinjaRMM
- Datto RMM
- Any RMM supporting PowerShell variables

## Version History

### Latest Version Features
- ✅ CBB executable integration for SSE restriction bypass
- ✅ Forever Forward Incremental with new backup format
- ✅ Automated backup prefix with DNS-friendly sanitization
- ✅ Enhanced plan validation and idempotent operations
- ✅ Disabled email notifications with event logging
- ✅ Comprehensive error handling and fallback methods
- ✅ Hybrid approach (PowerShell + CBB) for maximum compatibility

---

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review the generated log files
3. Test CBB executable manually
4. Verify MSP360 agent installation and service status

**Note**: This script is specifically designed for MSP360 staging environments and may require modification for production use. 