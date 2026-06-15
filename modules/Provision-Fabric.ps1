<#PSScriptInfo

.VERSION 1.0.0

.GUID 61f11d3f-ff9d-4141-b3bc-589d3c64a759

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Microsoft365 Azure Purview

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Provision Microsoft Fabric capacity, workspace, and lakehouse for agent data

.RELEASENOTES
Initial version metadata for Provision Microsoft Fabric capacity, workspace, and lakehouse for agent data.

#>
<#
.SYNOPSIS
    Provision Microsoft Fabric capacity, workspace, and lakehouse for agent data.
.DESCRIPTION
    Creates Fabric infrastructure for the Emma Leroy (Engineering) agent workload.
    Emma generates multi-format data files (CSV, JSON, MD, HTML, SVG, XML, TXT) that
    are dual-written to OneLake (lakehouse) and SharePoint.

    === RESOURCES CREATED ===

    1. FABRIC CAPACITY (F2, $Config.tenant.location)
       Minimum SKU for lakehouse workloads. ~$0.36/hr when active.
       -> Set fabricEnabled=false in agents.json to skip entirely.

    2. FABRIC WORKSPACE (CorpLab-DataPlatform)
       Assigned to the F2 capacity. Contains the lakehouse.

    3. LAKEHOUSE (LakehouseCorpLab)
       OneLake storage for Engineering department data.
       Organized: datasets/, schemas/, reports/, dashboards/, diagrams/.

    Supports two modes:
      - Create: provisions new Fabric resources from scratch
      - Existing: prompts for existing workspace/lakehouse IDs

    Stores AgentFabricWorkspaceId and AgentFabricLakehouseId in Automation variables.

    PREREQUISITE: The app registration must have storage.azure.com/user_impersonation
    scope for OneLake ROPC access.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER Mode
    'create' (default) or 'existing'. In 'existing' mode, prompts for IDs.
#>
param(
    $Config,
    [string]$Mode = 'create'
)

$ErrorActionPreference = 'Stop'
$sub     = $Config.tenant.subscriptionId
$rg      = $Config.infrastructure.resourceGroup
$loc     = $Config.tenant.location
$aaName  = $Config.infrastructure.automationAccountName

# Resolve actual AA resource group
$aaRg = $rg
$aaCheck = az automation account show -n $aaName -g $rg --query name -o tsv 2>$null
if (-not $aaCheck) {
    $aaOther = az automation account list --query "[?name=='$aaName'].resourceGroup" -o tsv 2>$null
    if ($aaOther) { $aaRg = $aaOther }
}

# ARM helpers
$mgtToken = az account get-access-token --query accessToken -o tsv 2>$null
$mgtH = @{Authorization = "Bearer $mgtToken"; 'Content-Type' = 'application/json'}
$varBase = "https://management.azure.com/subscriptions/$sub/resourceGroups/$aaRg/providers/Microsoft.Automation/automationAccounts/$aaName/variables"

function Set-AAVariable {
    param([string]$Name, [string]$Value, [bool]$Encrypted = $false)
    $body = @{properties = @{value = "`"$Value`""; isEncrypted = $Encrypted}} | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Method PUT -Uri "$varBase/${Name}?api-version=2023-11-01" `
        -Headers $mgtH -Body $body | Out-Null
}

# ============================================================================
# MODE: EXISTING
# ============================================================================
if ($Mode -eq 'existing') {
    Write-Host "  --- Existing Fabric Resources Mode ---" -ForegroundColor White

    $wsId = Read-Host "    Fabric workspace ID (GUID)"
    if (-not $wsId) { Write-Host "    [ERROR] Workspace ID required." -ForegroundColor Red; return }

    $lhId = Read-Host "    Fabric lakehouse ID (GUID)"
    if (-not $lhId) { Write-Host "    [ERROR] Lakehouse ID required." -ForegroundColor Red; return }

    Set-AAVariable -Name 'AgentFabricWorkspaceId' -Value $wsId
    Set-AAVariable -Name 'AgentFabricLakehouseId' -Value $lhId
    Write-Host "    [OK] Fabric variables stored" -ForegroundColor Green
    return
}

# ============================================================================
# CREATE: FABRIC CAPACITY (F2)
# ============================================================================
$capName = 'fabriclabcap'

# Check if Fabric provider is registered
$fabricProvider = az provider show --namespace Microsoft.Fabric --query registrationState -o tsv 2>$null
if ($fabricProvider -ne 'Registered') {
    Write-Host "  Registering Microsoft.Fabric provider..." -NoNewline
    az provider register --namespace Microsoft.Fabric -o none 2>$null
    Write-Host " [OK] (may take 1-2 min to propagate)" -ForegroundColor Green
}

Write-Host "  Creating Fabric capacity '$capName' (F2)..." -NoNewline

$capExists = az resource show --resource-type "Microsoft.Fabric/capacities" `
    --name $capName -g $rg --query name -o tsv 2>$null

if ($capExists) {
    Write-Host " [EXISTS]" -ForegroundColor DarkYellow
} else {
    # --- Region availability pre-check ---------------------------------------
    # Confirm the F2 SKU is actually offered in $loc BEFORE the PUT. The create
    # API returns a generic error that conflates "region unavailable" with
    # "tenant not onboarded to Fabric", so we resolve the region question first
    # and use it to classify any later failure accurately.
    # $f2Available: $true = offered, $false = not offered, $null = check failed.
    $f2Available = $null
    try {
        $skuResp = az rest --method get `
            --uri "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Fabric/skus?api-version=2023-11-01" `
            -o json 2>$null | ConvertFrom-Json
        if ($skuResp -and $skuResp.value) {
            $locKey = ($loc -replace '\s', '').ToLowerInvariant()
            $f2Regions = @($skuResp.value |
                Where-Object { $_.name -eq 'F2' } |
                ForEach-Object { $_.locations } |
                ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
            # Only treat the check as conclusive when we actually got a region
            # list. An empty list means the response shape changed or F2 was not
            # enumerated; stay $null (inconclusive) rather than false-skipping.
            if ($f2Regions.Count -gt 0) {
                $f2Available = [bool]($f2Regions -contains $locKey)
            }
        }
    } catch { $f2Available = $null }

    if ($f2Available -eq $false) {
        Write-Host " [SKIP]" -ForegroundColor DarkYellow
        Write-Host "    Fabric F2 is not offered in region '$loc'. Provisioning skipped (Fabric is optional)." -ForegroundColor Yellow
        Write-Host "    Action: choose an F2-supported region for the lab, or create the capacity manually in a supported region and rerun with [E] (use existing)." -ForegroundColor Yellow
        return
    }

    # Get admin UPN for capacity admin
    $adminUpn = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null

    # GUARD: a Fabric capacity requires at least one administrator. When a
    # Continuous Access Evaluation (CAE) token challenge hits mid-run, the az
    # call above returns empty and the create would fail later with a confusing
    # "subCode 12: At least one capacity administrator is required". Detect the
    # empty admin here and give the real, actionable cause instead.
    if ([string]::IsNullOrWhiteSpace($adminUpn)) {
        Write-Host " [SKIP]" -ForegroundColor DarkYellow
        Write-Host ''
        Write-Host "    Could not resolve the capacity administrator (az ad signed-in-user returned nothing)." -ForegroundColor Yellow
        Write-Host "    Cause: the Azure session needs re-authentication (Continuous Access Evaluation / token challenge)." -ForegroundColor Yellow
        Write-Host "    Fix: refresh your sign-in, then rerun Step 4c:" -ForegroundColor Cyan
        Write-Host "      az logout" -ForegroundColor Cyan
        Write-Host "      az login --tenant $($Config.tenant.tenantId)" -ForegroundColor Cyan
        Write-Host "    Note: Fabric is OPTIONAL - the rest of the lab works without it." -ForegroundColor DarkYellow
        return
    }

    $capBody = @{
        location = $loc
        sku = @{name = 'F2'; tier = 'Fabric'}
        properties = @{
            administration = @{members = @($adminUpn)}
        }
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod -Method PUT `
            -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Fabric/capacities/${capName}?api-version=2023-11-01" `
            -Headers $mgtH -Body $capBody | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        # Classify the failure instead of always blaming the region.
        $failMsg = [string]$_.Exception.Message
        $failDetail = ''
        try {
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $failDetail = [string]$_.ErrorDetails.Message }
            elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Message) { $failDetail = [string]$_.Exception.InnerException.Message }
        } catch {}
        $combined = "$failMsg $failDetail"
        Write-Host " [FAIL]" -ForegroundColor Red
        if ($combined -match 'recognized by Microsoft Fabric' -or
            $combined -match 'Sign up for Microsoft Fabric' -or
            $combined -match 'subCode["\s:]+27(?:\D|$)') {
            # Tenant is not onboarded to Microsoft Fabric - NOT a region problem,
            # and NOT something this installer can fix non-interactively. Enabling
            # Fabric for a tenant lives on the Power BI / Fabric admin plane
            # (api.fabric.microsoft.com/v1/admin/tenantsettings), which requires a
            # delegated Tenant.ReadWrite.All token admin-consented to the calling
            # app. The az CLI first-party app does not carry that scope, so even a
            # Global Admin gets 401 here. This is a one-time, admin-gated action.
            $locNote = if ($f2Available -eq $true) { " F2 capacity IS available in '$loc' - the region is not the problem." } else { '' }
            Write-Host ''
            Write-Host '    ============================================================' -ForegroundColor Yellow
            Write-Host '    FABRIC NOT ENABLED ON THIS TENANT (manual one-time action)' -ForegroundColor Yellow
            Write-Host '    ============================================================' -ForegroundColor Yellow
            Write-Host "    Cause:  Microsoft Fabric has never been enabled for tenant" -ForegroundColor Yellow
            Write-Host "            $($Config.tenant.domain) (Azure error subCode 27)." -ForegroundColor Yellow
            if ($locNote) { Write-Host "   $locNote" -ForegroundColor Yellow }
            Write-Host '    Why the installer cannot do it: enabling Fabric is a Power BI/' -ForegroundColor Yellow
            Write-Host '            Fabric ADMIN-plane action (Tenant.ReadWrite.All); the az' -ForegroundColor Yellow
            Write-Host '            CLI token lacks that scope, so even Global Admin gets 401.' -ForegroundColor Yellow
            Write-Host '    Fix (pick ONE, do once, then rerun Step 4c):' -ForegroundColor Cyan
            Write-Host '      1. Portal: https://app.fabric.microsoft.com  -> sign in as a' -ForegroundColor Cyan
            Write-Host '         Fabric/Power BI admin -> Settings (gear) -> Admin portal ->' -ForegroundColor Cyan
            Write-Host '         Tenant settings -> enable Microsoft Fabric for the org' -ForegroundColor Cyan
            Write-Host '         (or start a Fabric trial), wait ~5-10 min to propagate.' -ForegroundColor Cyan
            Write-Host '      2. Admin portal: https://admin.powerplatform.microsoft.com ->' -ForegroundColor Cyan
            Write-Host '         enable the Fabric/Power BI service for the tenant.' -ForegroundColor Cyan
            Write-Host '    Details + CLI option: docs/fabric-tenant-enablement.md' -ForegroundColor Cyan
            Write-Host "    Note: Fabric is OPTIONAL - the rest of the lab works without it." -ForegroundColor DarkYellow
            Write-Host '    ============================================================' -ForegroundColor Yellow
        } elseif ($f2Available -eq $true) {
            Write-Host "    F2 is available in '$loc' but capacity creation failed: $failMsg" -ForegroundColor Yellow
        } else {
            Write-Host "    Could not confirm F2 availability in '$loc'. Creation failed: $failMsg" -ForegroundColor Yellow
        }
        return
    }
}

# Ensure capacity is active (not paused)
$capState = az resource show --resource-type "Microsoft.Fabric/capacities" `
    --name $capName -g $rg --query properties.state -o tsv 2>$null
if ($capState -eq 'Paused') {
    Write-Host "  Resuming Fabric capacity..." -NoNewline
    az resource invoke-action --action resume --resource-type "Microsoft.Fabric/capacities" `
        --name $capName -g $rg -o none 2>$null
    Write-Host " [OK]" -ForegroundColor Green
}

# ============================================================================
# CREATE: FABRIC WORKSPACE
# ============================================================================
$wsName = 'CorpLab-DataPlatform'
Write-Host "  Creating Fabric workspace '$wsName'..." -NoNewline

# Fabric REST API requires a Power BI token
$fabricToken = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv 2>$null
$fh = @{Authorization = "Bearer $fabricToken"; 'Content-Type' = 'application/json'}

# Check if workspace exists
$workspaces = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $fh
$ws = $workspaces.value | Where-Object { $_.displayName -eq $wsName }

if ($ws) {
    $wsId = $ws.id
    Write-Host " [EXISTS] $wsId" -ForegroundColor DarkYellow
} else {
    # Get capacity ID for assignment
    $capId = az resource show --resource-type "Microsoft.Fabric/capacities" `
        --name $capName -g $rg --query id -o tsv 2>$null

    $wsBody = @{displayName = $wsName; capacityId = $capId; description = 'Agent data platform'} | ConvertTo-Json
    try {
        $wsResult = Invoke-RestMethod -Method POST -Uri "https://api.fabric.microsoft.com/v1/workspaces" `
            -Headers $fh -Body $wsBody
        $wsId = $wsResult.id
        Write-Host " [OK] $wsId" -ForegroundColor Green
    } catch {
        Write-Host " [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

# ============================================================================
# CREATE: LAKEHOUSE
# ============================================================================
$lhName = 'LakehouseCorpLab'
Write-Host "  Creating lakehouse '$lhName'..." -NoNewline

$lakehouses = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/lakehouses" -Headers $fh
$lh = $lakehouses.value | Where-Object { $_.displayName -eq $lhName }

if ($lh) {
    $lhId = $lh.id
    Write-Host " [EXISTS] $lhId" -ForegroundColor DarkYellow
} else {
    $lhBody = @{displayName = $lhName; description = 'Engineering department data lake'} | ConvertTo-Json
    try {
        $lhResult = Invoke-RestMethod -Method POST `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/lakehouses" `
            -Headers $fh -Body $lhBody
        $lhId = $lhResult.id
        Write-Host " [OK] $lhId" -ForegroundColor Green
    } catch {
        Write-Host " [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

# ============================================================================
# STORE AA VARIABLES
# ============================================================================
Write-Host "  Storing AA variables..." -NoNewline
Set-AAVariable -Name 'AgentFabricWorkspaceId' -Value $wsId
Set-AAVariable -Name 'AgentFabricLakehouseId' -Value $lhId
Write-Host " [OK]" -ForegroundColor Green

Write-Host ""
Write-Host "  Fabric provisioned:" -ForegroundColor Green
Write-Host "    Capacity:  $capName (F2, ~`$0.36/hr)" -ForegroundColor Gray
Write-Host "    Workspace: $wsName ($wsId)" -ForegroundColor Gray
Write-Host "    Lakehouse: $lhName ($lhId)" -ForegroundColor Gray
Write-Host ""
Write-Host "  NOTE: F2 capacity costs ~`$260/month when running 24/7." -ForegroundColor Yellow
Write-Host "  Pause when not in use: az resource invoke-action --action pause ..." -ForegroundColor Yellow



