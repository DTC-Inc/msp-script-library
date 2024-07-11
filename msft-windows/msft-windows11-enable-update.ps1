<#
.SYNOPSIS
    Enables Windows 11 upgrade.
.DESCRIPTION
    Enables Windows 11 upgrade.
.EXAMPLE
    No parameters needed
    Enables Windows 11 upgrade.
.OUTPUTS
    None
.NOTES
    Minimum OS Architecture Supported: Windows 10
    Release Notes:
    Allows the upgrade offer to Windows 11 to appear to users
    (c) 2023 NinjaOne
    By using this script, you indicate your acceptance of the following legal terms as well as our Terms of Use at https://www.ninjaone.com/terms-of-use.
    Ownership Rights: NinjaOne owns and will continue to own all right, title, and interest in and to the script (including the copyright). NinjaOne is giving you a limited license to use the script in accordance with these legal terms. 
    Use Limitation: You may only use the script for your legitimate personal or internal business purposes, and you may not share the script with another party. 
    Republication Prohibition: Under no circumstances are you permitted to re-publish the script in any script library or website belonging to or under the control of any other software provider. 
    Warranty Disclaimer: The script is provided “as is” and “as available”, without warranty of any kind. NinjaOne makes no promise or guarantee that the script will be free from defects or that it will meet your specific needs or expectations. 
    Assumption of Risk: Your use of the script is at your own risk. You acknowledge that there are certain inherent risks in using the script, and you understand and assume each of those risks. 
    Waiver and Release: You will not hold NinjaOne responsible for any adverse or unintended consequences resulting from your use of the script, and you waive any legal or equitable rights or remedies you may have against NinjaOne relating to your use of the script. 
    EULA: If you are a NinjaOne customer, your use of the script is subject to the End User License Agreement applicable to you (EULA).
#>
[CmdletBinding()]
param ()

$Splat = @{
    Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    Name        = @("TargetReleaseVersion", "TargetReleaseVersionInfo")
    ErrorAction = "SilentlyContinue"
}

Remove-ItemProperty @Splat -Force
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "SvOfferDeclined" -Force -ErrorAction SilentlyContinue

$TargetResult = Get-ItemProperty @Splat
$OfferResult = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "SvOfferDeclined" -ErrorAction SilentlyContinue

if ($null -ne $TargetResult -or $null -ne $OfferResult) {
    Write-Host "Failed to enable Windows 11 Upgrade."
    exit 1
}
exit 0