# PowerShell script to list all members of the local Administrators group
# Enhanced version with better Active Directory detection
# Compatible with both Windows PowerShell and PowerShell Core

try {
    Write-Host "Retrieving local Administrators group members..." -ForegroundColor Green
    Write-Host "Computer: $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
    Write-Host ("-" * 50)

    # Function to determine account source more accurately
    function Get-AccountSource {
        param(
            [string]$AccountName,
            [string]$SID
        )
        
        # Check if it's a well-known SID first
        $wellKnownSIDs = @{
            'S-1-5-32-544' = 'Local Built-in'
            'S-1-5-32-545' = 'Local Built-in'
            'S-1-5-32-546' = 'Local Built-in'
            'S-1-5-18' = 'Local Built-in'
            'S-1-5-19' = 'Local Built-in'
            'S-1-5-20' = 'Local Built-in'
            'S-1-1-0' = 'Local Built-in'
            'S-1-5-11' = 'Local Built-in'
        }
        
        if ($wellKnownSIDs.ContainsKey($SID)) {
            return 'Local Built-in'
        }
        
        # Handle account name analysis
        if ($AccountName -match '\\') {
            $domain = $AccountName.Split('\')[0]
            $username = $AccountName.Split('\')[1]
            
            # First check: Is domain explicitly the local computer name?
            if ($domain -eq $env:COMPUTERNAME) {
                return 'Local'
            }
            
            # Second check: Azure AD pattern
            if ($AccountName -match 'AzureAD\\.*@.*') {
                return 'EntraID'
            }
            
            # Third check: NT AUTHORITY accounts
            if ($domain -eq 'NT AUTHORITY') {
                return 'Local Built-in'
            }
            
            # Fourth check: Check if the account actually exists locally
            try {
                $localUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
                if ($localUser) {
                    return 'Local'
                }
                
                $localGroup = Get-LocalGroup -Name $username -ErrorAction SilentlyContinue
                if ($localGroup) {
                    return 'Local'
                }
            } catch {
                # Continue with other checks
            }
        } else {
            # No domain prefix - check if it exists locally
            try {
                $localUser = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
                if ($localUser) {
                    return 'Local'
                }
                
                $localGroup = Get-LocalGroup -Name $AccountName -ErrorAction SilentlyContinue
                if ($localGroup) {
                    return 'Local'
                }
            } catch {
                # Continue with other checks
            }
        }
        
        # SID-based analysis for more precise detection
        if ($SID -and $SID -ne "Unknown") {
            # Well-known local SIDs pattern
            if ($SID -match '^S-1-5-(18|19|20|32-.*)$') {
                return 'Local Built-in'
            }
            
            # Get the machine SID to compare
            try {
                $machineSid = (Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$env:USERNAME'" -ErrorAction SilentlyContinue | Select-Object -First 1).SID
                if ($machineSid) {
                    $machineSidPrefix = $machineSid -replace '-\d+$', ''
                    if ($SID.StartsWith($machineSidPrefix)) {
                        return 'Local'
                    }
                }
            } catch {
                # Alternative method to get machine SID
                try {
                    $localAccounts = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction SilentlyContinue
                    if ($localAccounts) {
                        $machineSidPrefix = ($localAccounts | Select-Object -First 1).SID -replace '-\d+$', ''
                        if ($SID.StartsWith($machineSidPrefix)) {
                            return 'Local'
                        }
                    }
                } catch {
                    # Continue with domain check
                }
            }
            
            # Domain SID pattern check - only if we have a domain to compare against
            if ($SID -match '^S-1-5-21-\d+-\d+-\d+-\d+$') {
                # This is a domain-style SID, but we need to verify it's actually from a domain
                try {
                    $domainCheck = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
                    # If we can get domain info and account has domain prefix that matches, it's likely AD
                    if ($AccountName -match '\\') {
                        $domain = $AccountName.Split('\')[0]
                        if ($domain -eq $domainCheck.Name.Split('.')[0] -or $domain -eq $domainCheck.Name) {
                            return 'ActiveDirectory'
                        }
                    }
                } catch {
                    # Not domain joined - this SID pattern could still be local
                    # If we can't verify domain membership, and account isn't verified as local above,
                    # we'll default to unknown rather than assume AD
                }
            }
        }
        
        # Final check: If account has domain prefix that's not the local computer
        if ($AccountName -match '\\') {
            $domain = $AccountName.Split('\')[0]
            if ($domain -ne $env:COMPUTERNAME -and $domain -ne '.' -and $domain -ne 'NT AUTHORITY') {
                # Only classify as AD if we can verify domain connectivity
                try {
                    $domainCheck = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
                    if ($domain -eq $domainCheck.Name.Split('.')[0] -or $domain -eq $domainCheck.Name) {
                        return 'ActiveDirectory'
                    }
                } catch {
                    # Can't verify domain - could be old domain reference
                    return 'Unknown'
                }
                
                # If domain prefix exists but doesn't match current domain, might be external domain
                return 'ActiveDirectory'
            }
        }
        
        return 'Unknown'
    }

    # Get the local Administrators group
    $adminGroup = Get-LocalGroup | Where-Object { $_.SID -eq "S-1-5-32-544" }
    
    if ($adminGroup) {
        Write-Host "Local Administrators Group: $($adminGroup.Name)" -ForegroundColor Yellow
        Write-Host ("-" * 50)
        
        $adminMembers = @()
        $orphanedSIDs = @()
        
        # Primary method: Try Get-LocalGroupMember first
        try {
            $rawMembers = Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop
            
            foreach ($member in $rawMembers) {
                $accountSource = Get-AccountSource -AccountName $member.Name -SID $member.SID.Value
                
                $memberObj = [PSCustomObject]@{
                    Name = $member.Name
                    ObjectClass = $member.ObjectClass
                    PrincipalSource = $accountSource
                    SID = $member.SID.Value
                    Enabled = $null
                }
                $adminMembers += $memberObj
            }
            
        } catch {
            Write-Host "Get-LocalGroupMember failed, using alternative methods..." -ForegroundColor Yellow
            
            # Alternative method 1: Use ADSI
            try {
                $group = [ADSI]"WinNT://$env:COMPUTERNAME/$($adminGroup.Name),group"
                $members = $group.Invoke("Members")
                
                foreach ($member in $members) {
                    try {
                        $memberPath = $member.GetType().InvokeMember("ADsPath", 'GetProperty', $null, $member, $null)
                        $memberName = $member.GetType().InvokeMember("Name", 'GetProperty', $null, $member, $null)
                        $memberClass = $member.GetType().InvokeMember("Class", 'GetProperty', $null, $member, $null)
                        
                        # Extract domain/computer from path
                        $pathParts = $memberPath -replace 'WinNT://', '' -split '/'
                        $domain = $pathParts[0]
                        $account = $pathParts[1]
                        
                        $fullName = if ($domain -ne $env:COMPUTERNAME) { "$domain\$memberName" } else { "$env:COMPUTERNAME\$memberName" }
                        
                        # Determine object class
                        $objClass = switch ($memberClass) {
                            'User' { 'User' }
                            'Group' { 'Group' }
                            default { 'User' }
                        }
                        
                        # Get SID
                        try {
                            $sid = (New-Object System.Security.Principal.SecurityIdentifier($member.GetType().InvokeMember("objectSid", 'GetProperty', $null, $member, $null), 0)).Value
                        } catch {
                            $sid = "Unknown"
                        }
                        
                        $accountSource = Get-AccountSource -AccountName $fullName -SID $sid
                        
                        $memberObj = [PSCustomObject]@{
                            Name = $fullName
                            ObjectClass = $objClass
                            PrincipalSource = $accountSource
                            SID = $sid
                            Enabled = $null
                        }
                        $adminMembers += $memberObj
                        
                    } catch {
                        Write-Host "Error processing member: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
                
            } catch {
                Write-Host "ADSI method failed, trying net command..." -ForegroundColor Yellow
                
                # Alternative method 2: Parse net localgroup output
                $netOutput = & net localgroup $adminGroup.Name 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $inMemberSection = $false
                    
                    foreach ($line in $netOutput) {
                        if ($line -match "^-+$") {
                            $inMemberSection = $true
                            continue
                        }
                        
                        if ($inMemberSection -and $line.Trim() -ne "" -and $line -notmatch "command completed successfully") {
                            $memberName = $line.Trim()
                            
                            # Check if it's an orphaned SID
                            if ($memberName -match "^S-1-.*") {
                                $orphanedSIDs += $memberName
                            } else {
                                # Determine account source from name pattern
                                $accountSource = if ($memberName -notmatch '\\' -or $memberName -match "^$env:COMPUTERNAME\\") {
                                    'Local'
                                } elseif ($memberName -match 'AzureAD\\.*@.*') {
                                    'EntraID'
                                } else {
                                    'ActiveDirectory'
                                }
                                
                                $memberObj = [PSCustomObject]@{
                                    Name = $memberName
                                    ObjectClass = 'Unknown'
                                    PrincipalSource = $accountSource
                                    SID = 'Unknown'
                                    Enabled = $null
                                }
                                $adminMembers += $memberObj
                            }
                        }
                    }
                }
            }
        }
        
        # Enhanced account status checking
        foreach ($member in $adminMembers) {
            if ($member.PrincipalSource -eq "Local" -and $member.ObjectClass -eq "User") {
                try {
                    $username = $member.Name
                    if ($username.Contains('\')) {
                        $username = $username.Split('\')[1]
                    }
                    
                    # Try multiple methods to get local user info
                    try {
                        $localUser = Get-LocalUser -Name $username -ErrorAction Stop
                        $member.Enabled = $localUser.Enabled
                    } catch {
                        # Fallback to ADSI for local users
                        try {
                            $user = [ADSI]"WinNT://$env:COMPUTERNAME/$username,user"
                            $member.Enabled = -not [bool]($user.UserFlags.Value -band 2)
                        } catch {
                            $member.Enabled = $null
                        }
                    }
                } catch {
                    $member.Enabled = $null
                }
            }
        }
        
        $totalValidMembers = $adminMembers.Count
        $totalOrphanedSIDs = $orphanedSIDs.Count
        
        Write-Host "Found $totalValidMembers valid member(s) and $totalOrphanedSIDs orphaned SID(s):" -ForegroundColor Green
        Write-Host ""
        
        # Display valid members with enhanced information
        if ($adminMembers.Count -gt 0) {
            Write-Host "VALID MEMBERS:" -ForegroundColor Green
            foreach ($member in $adminMembers) {
                Write-Host "Name: $($member.Name)" -ForegroundColor White
                Write-Host "Type: $($member.ObjectClass)" -ForegroundColor Gray
                Write-Host "Source: $($member.PrincipalSource)" -ForegroundColor Gray
                
                switch ($member.PrincipalSource) {
                    "Local" {
                        Write-Host "Account Type: Local Account" -ForegroundColor Blue
                        
                        if ($member.ObjectClass -eq "User" -and $null -ne $member.Enabled) {
                            $statusColor = if ($member.Enabled) { "Green" } else { "Red" }
                            $statusText = if ($member.Enabled) { "ENABLED" } else { "DISABLED" }
                            Write-Host "Account Status: $statusText" -ForegroundColor $statusColor
                            
                            # Get additional local user details
                            try {
                                $username = $member.Name.Split('\')[-1]
                                $localUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
                                if ($localUser) {
                                    Write-Host "Last Logon: $($localUser.LastLogon)" -ForegroundColor Gray
                                    Write-Host "Password Last Set: $($localUser.PasswordLastSet)" -ForegroundColor Gray
                                    Write-Host "Password Required: $($localUser.PasswordRequired)" -ForegroundColor Gray
                                    Write-Host "User May Change Password: $($localUser.UserMayChangePassword)" -ForegroundColor Gray
                                }
                            } catch {
                                Write-Host "Additional details: Not available" -ForegroundColor Yellow
                            }
                        }
                    }
                    "ActiveDirectory" {
                        Write-Host "Account Type: Domain Account" -ForegroundColor Magenta
                        if ($member.Name -match '\\') {
                            $domain = $member.Name.Split('\')[0]
                            Write-Host "Domain: $domain" -ForegroundColor Magenta
                        }
                        
                        # Try to verify domain connectivity
                        try {
                            $domainInfo = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
                            Write-Host "Domain Connection: Available ($($domainInfo.Name))" -ForegroundColor Green
                        } catch {
                            Write-Host "Domain Connection: Not available or not domain-joined" -ForegroundColor Yellow
                        }
                        
                        # Check if RSAT tools are available for more details
                        try {
                            if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
                                $username = $member.Name.Split('\')[-1]
                                $adUser = Get-ADUser -Identity $username -Properties Enabled,LastLogonDate -ErrorAction SilentlyContinue
                                if ($adUser) {
                                    Write-Host "AD Account Status: $(if ($adUser.Enabled) { 'ENABLED' } else { 'DISABLED' })" -ForegroundColor $(if ($adUser.Enabled) { "Green" } else { "Red" })
                                    Write-Host "AD Last Logon: $($adUser.LastLogonDate)" -ForegroundColor Gray
                                }
                            } else {
                                Write-Host "AD Details: RSAT tools not available" -ForegroundColor Yellow
                            }
                        } catch {
                            Write-Host "AD Details: Unable to query" -ForegroundColor Yellow
                        }
                    }
                    "EntraID" {
                        Write-Host "Account Type: Entra ID (Azure AD) Account" -ForegroundColor Cyan
                        if ($member.Name -match "@") {
                            $domain = $member.Name.Split('@')[1]
                            Write-Host "Tenant Domain: $domain" -ForegroundColor Cyan
                        }
                        Write-Host "Authentication: Cloud-based" -ForegroundColor Cyan
                    }
                    "Local Built-in" {
                        Write-Host "Account Type: Built-in System Account" -ForegroundColor DarkCyan
                        Write-Host "Note: System-level account" -ForegroundColor DarkCyan
                    }
                    default {
                        Write-Host "Account Type: Unknown" -ForegroundColor Yellow
                    }
                }
                
                if ($member.SID -and $member.SID -ne "Unknown") {
                    Write-Host "SID: $($member.SID)" -ForegroundColor DarkGray
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
                Write-Host "Cleanup Command: net localgroup `"$($adminGroup.Name)`" `"$sid`" /delete" -ForegroundColor Cyan
                Write-Host ("-" * 30)
            }
        }
        
        # Enhanced summary
        Write-Host ""
        Write-Host "SUMMARY:" -ForegroundColor Yellow
        $localCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "Local" }).Count
        $domainCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "ActiveDirectory" }).Count
        $entraIdCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "EntraID" }).Count
        $builtinCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "Local Built-in" }).Count
        $unknownCount = ($adminMembers | Where-Object { $_.PrincipalSource -eq "Unknown" }).Count
        
        Write-Host "=== ACCOUNT BREAKDOWN ===" -ForegroundColor White
        Write-Host "Total Valid Members: $totalValidMembers"
        Write-Host ""
        Write-Host "By Account Source:" -ForegroundColor Yellow
        Write-Host "  Local Accounts: $localCount" -ForegroundColor Blue
        Write-Host "  Domain Accounts (AD): $domainCount" -ForegroundColor Magenta
        Write-Host "  Entra ID Accounts: $entraIdCount" -ForegroundColor Cyan
        Write-Host "  Built-in Accounts: $builtinCount" -ForegroundColor DarkCyan
        if ($unknownCount -gt 0) {
            Write-Host "  Unknown Source: $unknownCount" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "Issues Found:" -ForegroundColor Red
        Write-Host "  Orphaned SIDs: $totalOrphanedSIDs"
        
        # Security recommendations
        Write-Host ""
        Write-Host "=== SECURITY RECOMMENDATIONS ===" -ForegroundColor Yellow
        
        $disabledCount = ($adminMembers | Where-Object { $_.Enabled -eq $false }).Count
        if ($disabledCount -gt 0) {
            Write-Host "⚠️  $disabledCount disabled account(s) found in Administrators group." -ForegroundColor Red
            Write-Host "   → Remove disabled accounts from administrative groups." -ForegroundColor Yellow
        }
        
        if ($totalOrphanedSIDs -gt 0) {
            Write-Host "⚠️  $totalOrphanedSIDs orphaned SID(s) found." -ForegroundColor Red
            Write-Host "   → Clean up orphaned SIDs from the group." -ForegroundColor Yellow
        }
        
        if ($domainCount -gt 0) {
            Write-Host "ℹ️  $domainCount domain account(s) detected." -ForegroundColor Magenta
            Write-Host "   → Verify these accounts are still needed and active in AD." -ForegroundColor Magenta
        }
        
        if ($entraIdCount -gt 0) {
            Write-Host "ℹ️  $entraIdCount Entra ID account(s) detected." -ForegroundColor Cyan
            Write-Host "   → Ensure appropriate conditional access policies are applied." -ForegroundColor Cyan
        }
        
        $totalActiveAdmins = ($adminMembers | Where-Object { $_.PrincipalSource -in @('Local', 'ActiveDirectory', 'EntraID') -and $_.Enabled -ne $false }).Count
        if ($totalActiveAdmins -gt 5) {
            Write-Host "⚠️  $totalActiveAdmins potentially active administrative accounts found." -ForegroundColor Yellow
            Write-Host "   → Consider implementing least privilege access principles." -ForegroundColor Yellow
        }
        
    } else {
        Write-Host "Could not locate the local Administrators group." -ForegroundColor Red
        exit 1
    }
    
} catch {
    Write-Host "Error occurred while retrieving administrator group members:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Stack Trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Script completed successfully." -ForegroundColor Green
