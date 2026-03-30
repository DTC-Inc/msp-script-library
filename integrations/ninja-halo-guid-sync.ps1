# Add NinjaRMM DTC ORG GUID to Halo GUID sync script

# ============================================================
# NinjaRMM → Halo PSA GUID Sync
# Reads DTC Org GUID from Ninja custom fields and writes
# it to DTC Client GUID in Halo PSA for all matching clients
# ============================================================

# --- CONFIGURATION ---
$HaloClientId     = "YOUR_HALO_CLIENT_ID_IN_1Password"
$HaloClientSecret = 'YOUR_HALO_CLIENT_SECRET_IN_1Password'
$HaloBaseUrl      = "https://psa.dtctoday.com"
$HaloTenant       = "dtctoday"
$HaloScope        = "read:customers edit:customers"

$NinjaClientId     = "YOUR_NINJA_CLIENT_ID_IN_1Password"
$NinjaClientSecret = 'YOUR_NINJA_CLIENT_ID_IN_1Password'
$NinjaBaseUrl      = "https://app.ninjarmm.com"

# --- AUTHENTICATE: HALO ---
$haloTokenResp = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/auth/token?tenant=$HaloTenant" -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type    = "client_credentials"
    client_id     = $HaloClientId
    client_secret = $HaloClientSecret
    scope         = $HaloScope
}
$haloToken = $haloTokenResp.access_token
if (-not $haloToken) {
    Write-Host "❌ Halo auth failed — response was:"
    $haloTokenResp | ConvertTo-Json
    exit
}
Write-Host "✅ Halo authenticated"

# --- AUTHENTICATE: NINJA ---
$ninjaTokenResp = Invoke-RestMethod -Method Post -Uri "$NinjaBaseUrl/ws/oauth/token" -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type    = "client_credentials"
    client_id     = $NinjaClientId
    client_secret = $NinjaClientSecret
    scope         = "monitoring management"
}
$ninjaToken = $ninjaTokenResp.access_token
if (-not $ninjaToken) {
    Write-Host "❌ Ninja auth failed — response was:"
    $ninjaTokenResp | ConvertTo-Json
    exit
}
Write-Host "✅ Ninja authenticated"

$ninjaHeaders = @{ Authorization = "Bearer $ninjaToken" }
$haloHeaders  = @{ Authorization = "Bearer $haloToken" }

# --- GET ALL NINJA ORGS ---
$ninjaOrgs = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organizations" -Headers $ninjaHeaders
Write-Host "📋 Found $($ninjaOrgs.Count) Ninja orgs"

$results = @()

foreach ($org in $ninjaOrgs) {
    $orgId   = $org.id
    $orgName = $org.name

    # Get custom fields for this org
    try {
        $fields = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organization/$orgId/custom-fields" -Headers $ninjaHeaders
    } catch {
        Write-Host "⚠️  Could not get custom fields for $orgName — skipping"
        continue
    }

    $guid = $fields.dtcOrgGuid
    if (-not $guid) {
        Write-Host "⚠️  No DTC Org GUID set for $orgName — skipping"
        continue
    }

    # Find matching Halo client by name
    $encodedName = [System.Web.HttpUtility]::UrlEncode($orgName)
    try {
        $haloSearch = Invoke-RestMethod -Method Get -Uri "$HaloBaseUrl/api/client?search=$encodedName" -Headers $haloHeaders
    } catch {
        Write-Host "⚠️  Halo search failed for $orgName — $($_.Exception.Message)"
        Write-Host "    Response: $($_.ErrorDetails.Message)"
        continue
    }

    $haloClient = $haloSearch.clients | Where-Object { $_.name -eq $orgName } | Select-Object -First 1

    if (-not $haloClient) {
        Write-Host "⚠️  No exact Halo match for '$orgName' — skipping"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No Halo match"; GUID = $guid }
        continue
    }

    $haloClientId = $haloClient.id

    # Write GUID to Halo custom field
    $body = ConvertTo-Json -Depth 5 -InputObject @(
        [ordered]@{
            id           = $haloClientId
            customfields = @(
                [ordered]@{
                    name  = "DTC Client GUID"
                    value = $guid
                }
            )
        }
    )

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/api/client" -Headers $haloHeaders -ContentType "application/json" -Body $body
        Write-Host "✅ Updated $orgName → $guid"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Updated"; GUID = $guid }
    } catch {
        Write-Host "❌ Failed to update $orgName — $($_.Exception.Message)"
        Write-Host "    Response: $($_.ErrorDetails.Message)"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Failed"; GUID = $guid }
    }
}

# --- SUMMARY ---
Write-Host ""
Write-Host "===== SYNC SUMMARY ====="
$results | Format-Table -AutoSize# ============================================================
# NinjaRMM → Halo PSA GUID Sync
# Reads DTC Org GUID from Ninja custom fields and writes
# it to DTC Client GUID in Halo PSA for all matching clients
# ============================================================

# --- CONFIGURATION ---
$HaloClientId     = "25542a6d-2d0e-4093-bf82-e11edc64faf6"
$HaloClientSecret = '67t5ZMI1p08--LtBe7eAr3xi6-AvT1aowBKzllXYuyA'
$HaloBaseUrl      = "https://psa.dtctoday.com"
$HaloTenant       = "dtctoday"
$HaloScope        = "read:customers edit:customers"

$NinjaClientId     = "0S1xEjce1FQp7Rbn_GJTrSWTp64"
$NinjaClientSecret = 'z4ExyKaDiIyLKAnEHmo0kG2uwzd2SHV0Dz4zmny7Z8JXWRhPUOjpsA'
$NinjaBaseUrl      = "https://app.ninjarmm.com"

# --- AUTHENTICATE: HALO ---
$haloTokenResp = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/auth/token?tenant=$HaloTenant" -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type    = "client_credentials"
    client_id     = $HaloClientId
    client_secret = $HaloClientSecret
    scope         = $HaloScope
}
$haloToken = $haloTokenResp.access_token
if (-not $haloToken) {
    Write-Host "❌ Halo auth failed — response was:"
    $haloTokenResp | ConvertTo-Json
    exit
}
Write-Host "✅ Halo authenticated"

# --- AUTHENTICATE: NINJA ---
$ninjaTokenResp = Invoke-RestMethod -Method Post -Uri "$NinjaBaseUrl/ws/oauth/token" -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type    = "client_credentials"
    client_id     = $NinjaClientId
    client_secret = $NinjaClientSecret
    scope         = "monitoring management"
}
$ninjaToken = $ninjaTokenResp.access_token
if (-not $ninjaToken) {
    Write-Host "❌ Ninja auth failed — response was:"
    $ninjaTokenResp | ConvertTo-Json
    exit
}
Write-Host "✅ Ninja authenticated"

$ninjaHeaders = @{ Authorization = "Bearer $ninjaToken" }
$haloHeaders  = @{ Authorization = "Bearer $haloToken" }

# --- GET ALL NINJA ORGS ---
$ninjaOrgs = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organizations" -Headers $ninjaHeaders
Write-Host "📋 Found $($ninjaOrgs.Count) Ninja orgs"

$results = @()

foreach ($org in $ninjaOrgs) {
    $orgId   = $org.id
    $orgName = $org.name

    # Get custom fields for this org
    try {
        $fields = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organization/$orgId/custom-fields" -Headers $ninjaHeaders
    } catch {
        Write-Host "⚠️  Could not get custom fields for $orgName — skipping"
        continue
    }

    $guid = $fields.dtcOrgGuid
    if (-not $guid) {
        Write-Host "⚠️  No DTC Org GUID set for $orgName — skipping"
        continue
    }

    # Find matching Halo client by name
    $encodedName = [System.Web.HttpUtility]::UrlEncode($orgName)
    try {
        $haloSearch = Invoke-RestMethod -Method Get -Uri "$HaloBaseUrl/api/client?search=$encodedName" -Headers $haloHeaders
    } catch {
        Write-Host "⚠️  Halo search failed for $orgName — $($_.Exception.Message)"
        Write-Host "    Response: $($_.ErrorDetails.Message)"
        continue
    }

    $haloClient = $haloSearch.clients | Where-Object { $_.name -eq $orgName } | Select-Object -First 1

    if (-not $haloClient) {
        Write-Host "⚠️  No exact Halo match for '$orgName' — skipping"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No Halo match"; GUID = $guid }
        continue
    }

    $haloClientId = $haloClient.id

    # Write GUID to Halo custom field
    $body = ConvertTo-Json -Depth 5 -InputObject @(
        [ordered]@{
            id           = $haloClientId
            customfields = @(
                [ordered]@{
                    name  = "DTC Client GUID"
                    value = $guid
                }
            )
        }
    )

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/api/client" -Headers $haloHeaders -ContentType "application/json" -Body $body
        Write-Host "✅ Updated $orgName → $guid"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Updated"; GUID = $guid }
    } catch {
        Write-Host "❌ Failed to update $orgName — $($_.Exception.Message)"
        Write-Host "    Response: $($_.ErrorDetails.Message)"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Failed"; GUID = $guid }
    }
}

# --- SUMMARY ---
Write-Host ""
Write-Host "===== SYNC SUMMARY ====="
$results | Format-Table -AutoSize
