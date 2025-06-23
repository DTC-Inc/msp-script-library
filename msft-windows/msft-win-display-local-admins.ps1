# PowerShell script to list all members of the local Administrators group
# Compatible with NinjaOne RMM deployment

try {
    Write-Host "Retrieving local Administrators group members..." -ForegroundColor Green
    Write-Host "Computer: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ("-" * 50)

    # Get the local Administrators group (works with localized Windows versions)
    $adminGroup = Get-LocalGroup | Where-Object { $_.SID -eq "S-1-5-32-544" }
    
    if ($adminGroup) {
        Write-Host "Local Administrators Group: $($adminGroup.Name)" -ForegroundColor Yellow
        Write-Host ("-" * 50)
        
        # Get all members of the Administrators group with error handling for orphaned SIDs
        $adminMembers = @()
        $orphanedSIDs = @()
        
        try {
            $adminMembers = @(Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop)
        } catch [Microsoft.PowerShell.Commands.PrincipalNotFoundException] {
            # Handle orphaned SIDs by using alternative method
            Write-Host "Detected orphaned SIDs in group. Using alternative enumeration method..." -ForegroundColor Yellow
            
            # Use WMI/CIM to get group members and handle orphaned SIDs
            try {
                $group = Get-CimInstance -ClassName Win32_Group -Filter "Name='$($adminGroup.Name)'"
                $groupMembers = Get-CimAssociatedInstance -InputObject $group -ResultClassName Win32_Account -ErrorAction SilentlyContinue
                
                foreach ($member in $groupMembers) {
                    $memberObj = [PSCustomObject]@{
                        Name = "$($member.Domain)\$($member.Name)"
                        ObjectClass = if ($member.AccountType -eq 512) { "User" } else { "Group" }
                        PrincipalSource = if ($member.Domain -eq $env:COMPUTERNAME) { "Local" } else { "ActiveDirectory" }
                        SID = $member.SID
                    }
                    $adminMembers += $memberObj
                }
                
                # Also try to identify orphaned SIDs using net localgroup command
                $netOutput = net localgroup $adminGroup.Name 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $netOutput | ForEach-Object {
                        if ($_ -match "^S-1-.*") {
                            $orphanedSIDs += $_.Trim()
                        }
                    }
                }
                
            } catch {
                Write-Host "Alternative method also failed. Trying direct registry access..." -ForegroundColor Yellow
                # Fallback: try using net localgroup command only
                $netOutput = net localgroup $adminGroup.Name 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Using net localgroup output for available information..." -ForegroundColor Cyan
                }
            }
        }
        
        $totalValidMembers = $adminMembers.Count
        $totalOrphanedSIDs = $orphanedSIDs.Count
        
        Write-Host "Found $totalValidMembers valid member(s) and $totalOrphanedSIDs orphaned SID(s):" -ForegroundColor Green
        Write-Host ""
        
        # Display valid members
        if ($adminMembers.Count -gt 0) {
            Write-Host "VALID MEMBERS:" -ForegroundColor Green
            foreach ($member in $adminMembers) {
                Write-Host "Name: $($member.Name)" -ForegroundColor White
                Write-Host "Type: $($member.ObjectClass)" -ForegroundColor Gray
                Write-Host "Source: $($member.PrincipalSource)" -ForegroundColor Gray
                
                # Additional info for accounts
                if ($member.PrincipalSource -eq "ActiveDirectory") {
                    Write-Host "Domain Account: Yes" -ForegroundColor Magenta
                } else {
                    Write-Host "Local Account: Yes" -ForegroundColor Blue
                    
                    # Check if local account is enabled (only for local user accounts, not groups)
                    if ($member.ObjectClass -eq "User") {
                        try {
                            # Extract username from full name (remove computer name prefix if present)
                            $username = $member.Name
                            if ($username.Contains('\')) {
                                $username = $username.Split('\')[1]
                            }
                            
                            $localUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
                            if ($localUser) {
                                if ($localUser.Enabled) {
                                    Write-Host "Account Status: ENABLED" -ForegroundColor Green
                                } else {
                                    Write-Host "Account Status: DISABLED" -ForegroundColor Red
                                }
                                Write-Host "Last Logon: $($localUser.LastLogon)" -ForegroundColor Gray
                                Write-Host "Password Last Set: $($localUser.PasswordLastSet)" -ForegroundColor Gray
                                Write-Host "Password Required: $($localUser.PasswordRequired)" -ForegroundColor Gray
                                Write-Host "Password Expires: $($localUser.PasswordExpires)" -ForegroundColor Gray
                            } else {
                                Write-Host "Account Status: Unable to determine" -ForegroundColor Yellow
                            }
                        } catch {
                            Write-Host "Account Status: Error checking status" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "Group: Status check not applicable" -ForegroundColor Gray
                    }
                }
                
                Write-Host ("-" * 30)
            }
        }
        
        # Display orphaned SIDs
        if ($orphanedSIDs.Count -gt 0) {
            Write-Host ""
            Write-Host "ORPHANED SIDs (Deleted Accounts):" -ForegroundColor Red
            foreach ($sid in $orphanedSIDs) {
                Write-Host "SID: $sid" -ForegroundColor Red
                Write-Host "Status: Account deleted but SID remains in group" -ForegroundColor Yellow
                Write-Host "Action Required: Clean up orphaned SID" -ForegroundColor Yellow
                Write-Host ("-" * 30)
            }
            Write-Host ""
            Write-Host "NOTE: Orphaned SIDs should be removed from the Administrators group." -ForegroundColor Yellow
            Write-Host "Use: net localgroup Administrators `"$($orphanedSIDs[0])`" /delete" -ForegroundColor Cyan
        }
            
        # Summary with account status breakdown
        Write-Host ""
        Write-Host "SUMMARY:" -ForegroundColor Yellow
        $localCount = ($adminMembers | Where-Object { $_.PrincipalSource -ne "ActiveDirectory" }).Count
        $domainCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "ActiveDirectory" }).Count
        
        # Count enabled/disabled local user accounts
        $localUsers = $adminMembers | Where-Object { $_.PrincipalSource -ne "ActiveDirectory" -and $_.ObjectClass -eq "User" }
        $enabledLocalUsers = 0
        $disabledLocalUsers = 0
        
        foreach ($localUser in $localUsers) {
            try {
                $username = $localUser.Name
                if ($username.Contains('\')) {
                    $username = $username.Split('\')[1]
                }
                
                $userAccount = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
                if ($userAccount) {
                    if ($userAccount.Enabled) {
                        $enabledLocalUsers++
                    } else {
                        $disabledLocalUsers++
                    }
                }
            } catch {
                # Skip users we can't check
            }
        }
        
        Write-Host "Valid Members: $totalValidMembers"
        Write-Host "Local Members: $localCount"
        Write-Host "  - Local Users (Enabled): $enabledLocalUsers" -ForegroundColor Green
        Write-Host "  - Local Users (Disabled): $disabledLocalUsers" -ForegroundColor Red
        Write-Host "  - Local Groups: $(($adminMembers | Where-Object { $_.PrincipalSource -ne "ActiveDirectory" -and $_.ObjectClass -eq "Group" }).Count)"
        Write-Host "Domain Members: $domainCount"
        Write-Host "Orphaned SIDs: $totalOrphanedSIDs"
        Write-Host "Total Issues: $totalOrphanedSIDs"
        
        if ($disabledLocalUsers -gt 0) {
            Write-Host ""
            Write-Host "SECURITY NOTE: $disabledLocalUsers disabled local user(s) found in Administrators group." -ForegroundColor Yellow
            Write-Host "Consider removing disabled accounts from administrative groups." -ForegroundColor Yellow
        }
        
        if ($totalValidMembers -eq 0 -and $totalOrphanedSIDs -eq 0) {
            Write-Host "No members found in the Administrators group." -ForegroundColor Red
        }
        
    } else {
        Write-Host "Could not locate the local Administrators group." -ForegroundColor Red
        exit 1
    }
    
} catch {
    Write-Host "Error occurred while retrieving administrator group members:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Optional: Export to file for NinjaOne to collect
$outputPath = "$env:TEMP\LocalAdmins_$env:COMPUTERNAME.txt"
try {
    $output = @()
    $output += "Local Administrators Report"
    $output += "Computer: $env:COMPUTERNAME"
    $output += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $output += "=" * 50
    
    $adminGroup = Get-LocalGroup | Where-Object { $_.SID -eq "S-1-5-32-544" }
    $adminMembers = @()
    $orphanedSIDs = @()
    
    foreach ($member in $adminMembers) {
        $output += "Name: $($member.Name)"
        $output += "Type: $($member.ObjectClass)"
        $output += "Source: $($member.PrincipalSource)"
        
        # Add account status for local users
        if ($member.PrincipalSource -ne "ActiveDirectory" -and $member.ObjectClass -eq "User") {
            try {
                $username = $member.Name
                if ($username.Contains('\')) {
                    $username = $username.Split('\')[1]
                }
                
                $localUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
                if ($localUser) {
                    $output += "Status: $(if ($localUser.Enabled) { 'ENABLED' } else { 'DISABLED' })"
                    $output += "Last Logon: $($localUser.LastLogon)"
                    $output += "Password Last Set: $($localUser.PasswordLastSet)"
                }
            } catch {
                $output += "Status: Unable to determine"
            }
        }
        
        $output += "-" * 30
    }
    
    if ($orphanedSIDs.Count -gt 0) {
        $output += ""
        $output += "ORPHANED SIDs:"
        foreach ($sid in $orphanedSIDs) {
            $output += "SID: $sid (Deleted Account)"
            $output += "-" * 30
        }
    }
    
    $output | Out-File -FilePath $outputPath -Encoding UTF8
    Write-Host ""
    Write-Host "Report exported to: $outputPath" -ForegroundColor Green
    
} catch {
    Write-Host "Warning: Could not export report to file." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Script completed successfully." -ForegroundColor Green