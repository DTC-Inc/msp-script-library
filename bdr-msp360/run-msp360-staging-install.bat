@echo off
echo.
echo ========================================
echo MSP360 Staging Installation Script
echo ========================================
echo.
echo This will install and configure MSP360 with staging settings.
echo Running with PowerShell Execution Policy Bypass...
echo.
pause

powershell.exe -ExecutionPolicy Bypass -File "%~dp0msp360-staging-install-and-configure.ps1"

echo.
echo Script execution completed.
pause 