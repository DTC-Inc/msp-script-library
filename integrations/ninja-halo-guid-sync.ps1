# NinjaRMM to Halo PSA GUID Sync
#
# SYNOPSIS
#   Syncs the DTC Org GUID from NinjaRMM organizations to the DTC Client GUID
#   custom field in Halo PSA.
#
# NOTES
#   Documentation: BookStack page 1908
#   Schedule:      Weekly (Sundays 2:00 AM EDT) via NinjaRMM Scheduled Tasks
#
#   Replace all placeholder values below with real credentials before deploying.
#   Store credentials in 1Password under: Halo/NinjaRMM API - GUID Sync Secret
#   Never commit real credentials to this repository.

# --- CONFIGURATION ---
$HaloClientId      = "YOUR_HALO_CLIENT_ID"
$HaloClientSecret  = "YOUR_HALO_CLIENT_SECRET"
$HaloBaseUrl       = "https://psa.dtctoday.com"
$HaloScope         = "read:customers edit:customers"

$NinjaClientId     = "YOUR_NINJA_CLIENT_ID"
$NinjaClientSecret = "YOUR_NINJA_CLIENT_SECRET"
$NinjaBaseUrl      = "https://app.ninjarmm.com"

# --- AUTHENTICATE: HALO ---
try {
    $haloTokenResp = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/auth/token" `
        -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $HaloClientId
            client_secret = $HaloClientSecret
            scope         = $HaloScope
        }
    $haloToken   = $haloTokenResp.access_token
    $haloHeaders = @{ Authorization = "Bearer $haloToken" }
} catch {
    Write-Error "Halo auth failed: $($_.Exception.Message)"
    exit 1
}

# --- AUTHENTICATE: NINJA ---
try {
    $ninjaTokenResp = Invoke-RestMethod -Method Post -Uri "$NinjaBaseUrl/ws/oauth/token" `
        -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $NinjaClientId
            client_secret = $NinjaClientSecret
            scope         = "monitoring management"
        }
    $ninjaToken   = $ninjaTokenResp.access_token
    $ninjaHeaders = @{ Authorization = "Bearer $ninjaToken" }
} catch {
    Write-Error "Ninja auth failed: $($_.Exception.Message)"
    exit 1
}

# --- PULL NINJA ORGS ---
$orgs = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organizations" -Headers $ninjaHeaders

$results = @()

foreach ($org in $orgs) {
    $orgName = $org.name
    $orgId   = $org.id

    try {
        $cf   = Invoke-RestMethod -Method Get `
            -Uri "$NinjaBaseUrl/v2/organization/$orgId/custom-fields" -Headers $ninjaHeaders
        $guid = $cf.dtcOrgGuid
    } catch {
        Write-Host "Could not read custom fields for $orgName -- skipping"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($guid)) {
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No GUID"; GUID = "" }
        continue
    }

    try {
        $haloSearch = Invoke-RestMethod -Method Get `
            -Uri "$HaloBaseUrl/api/client?search=$([uri]::EscapeDataString($orgName))" `
            -Headers $haloHeaders
    } catch {
        Write-Host "Halo search failed for $orgName -- skipping"
        continue
    }

    $haloClient = $haloSearch.clients | Where-Object { $_.name -eq $orgName } | Select-Object -First 1

    if (-not $haloClient) {
        Write-Host "No exact Halo match for $orgName -- skipping"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No Halo match"; GUID = $guid }
        continue
    }

    $clientUpdate = @{
        id           = $haloClient.id
        customfields = @(
            @{ name = "CFDtcClientGuid"; value = $guid }
        )
    }
    $body = "[" + ($clientUpdate | ConvertTo-Json -Depth 5) + "]"

    try {
        Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/api/client" `
            -Headers $haloHeaders -ContentType "application/json" -Body $body | Out-Null
        Write-Host "Updated $orgName"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Updated"; GUID = $guid }
    } catch {
        $errorDetail = $_.ErrorDetails.Message
        Write-Host "Failed to update $orgName -- $($_.Exception.Message) | $errorDetail"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Failed"; GUID = $guid }
    }
}

Write-Host ""
Write-Host "===== SYNC SUMMARY ====="
$results | Format-Table -AutoSize
