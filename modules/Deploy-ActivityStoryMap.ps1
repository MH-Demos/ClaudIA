<#PSScriptInfo

.VERSION 1.1.0

.GUID 377b3221-30aa-4184-80d1-bc9a5eb6b6d6

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
Deploys the Activity Story Map Azure frontend and API

.RELEASENOTES
Version 1.1.0 adds Entra-only Storage deployment, Flex Consumption, and OneDeploy support for hardened tenants.

#>
<#
.SYNOPSIS
    Deploys the Activity Story Map Azure frontend and API.
.DESCRIPTION
    Provisions a Storage static website for the UI and an Azure Function with
    managed identity for live ADX queries. The function identity is granted ADX
    database Viewer so the UI does not need secrets.
#>
param(
    [Parameter(Mandatory)]$Config,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-ShortHash {
    param([Parameter(Mandatory)][string]$Text, [int]$Length = 6)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, $Length)).ToLowerInvariant()
}

function Get-DomainCode {
    param([Parameter(Mandatory)][string]$Domain)
    $label = ($Domain -split '\.')[0]
    $code = ($label -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $code) { $code = 'agents' }
    return $code
}

function Get-StorageSafeName {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$DomainCode, [Parameter(Mandatory)][string]$Suffix)
    $base = ($Prefix + $DomainCode + $Suffix).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($base.Length -gt 24) { $base = $base.Substring(0, 24) }
    return $base
}

function Invoke-AzRestJson {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body
    )
    $token = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv 2>$null
    if (-not $token) { throw 'Could not acquire Azure management token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers
}

function Invoke-AAFunctionOneDeploy {
    param(
        [Parameter(Mandatory)][string]$FunctionAppName,
        [Parameter(Mandatory)][string]$ZipPath,
        [int]$TimeoutSeconds = 900
    )

    $token = [string](az account get-access-token --resource 'https://appservice.azure.com' --query accessToken -o tsv 2>$null)
    $token = $token.Trim()
    if (-not $token) { throw 'Could not acquire the App Service token required by Kudu OneDeploy.' }

    $scmBase = "https://${FunctionAppName}.scm.azurewebsites.net"
    $uri = "$scmBase/api/publish?RemoteBuild=false&Deployer=ClaudIA"
    $headers = @{ Authorization = ('{0} {1}' -f 'Bearer', $token) }
    $headers['Cache-Control'] = 'no-cache'
    $headers['User-Agent'] = 'ClaudIA-Installer'
    $headers['x-ms-client-request-id'] = [guid]::NewGuid().ToString()
    $response = Invoke-WebRequest -Method POST -Uri $uri -Headers $headers `
        -ContentType 'application/zip' -Body ([System.IO.File]::ReadAllBytes($ZipPath)) `
        -TimeoutSec 180 -SkipHttpErrorCheck -ErrorAction Stop
    if ($response.StatusCode -ne 202) {
        throw "Kudu OneDeploy returned HTTP $($response.StatusCode)."
    }

    $deploymentUri = [string]$response.Headers.Location
    if (-not $deploymentUri) { $deploymentUri = "$scmBase/api/deployments/latest" }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $deployment = Invoke-RestMethod -Method GET -Uri $deploymentUri -Headers $headers -TimeoutSec 60 -ErrorAction Stop
        $deploymentStatus = [int]$deployment.status
        if ($deploymentStatus -eq 4) { return }
        if ($deployment.complete -eq $true -or $deploymentStatus -eq 3) {
            $detail = @($deployment.message, $deployment.status_text, $deployment.progress) |
                Where-Object { $_ } | Select-Object -First 1
            throw "Kudu OneDeploy failed with status ${deploymentStatus}: $detail"
        }
        Start-Sleep -Seconds 10
    }

    throw "Kudu OneDeploy did not complete within $TimeoutSeconds seconds."
}

if (-not $Config.adx -or $Config.adx.enabled -ne $true) {
    throw 'Activity Story Map requires ADX telemetry to be enabled.'
}

$sub = [string]$Config.tenant.subscriptionId
$tenantId = [string]$Config.tenant.tenantId
$location = [string]$Config.tenant.location
$resourceGroup = [string]$Config.infrastructure.resourceGroup

az account set -s $sub 2>$null
$existingResourceGroupLocation = az group show -n $resourceGroup --query location -o tsv 2>$null
if ($existingResourceGroupLocation) {
    $location = $existingResourceGroupLocation
}

$domainCode = Get-DomainCode -Domain $Config.tenant.domain
$suffix = Get-ShortHash -Text "$sub-$resourceGroup-activity-story-map"

$existing = $Config.activityStoryMap
$siteStorageName = if ($existing.storageAccountName) { [string]$existing.storageAccountName } else { Get-StorageSafeName -Prefix 'st' -DomainCode "${domainCode}map" -Suffix $suffix }
$functionStorageName = if ($existing.functionStorageAccountName) { [string]$existing.functionStorageAccountName } else { Get-StorageSafeName -Prefix 'st' -DomainCode "${domainCode}fn" -Suffix $suffix }
$functionAppName = if ($existing.functionAppName) { [string]$existing.functionAppName } else { "func-$domainCode-story-$suffix" }

$clusterName = [string]$Config.adx.clusterName
$clusterRg = if ($Config.adx.resourceGroup) { [string]$Config.adx.resourceGroup } else { $resourceGroup }
$databaseName = [string]$Config.adx.databaseName
$tableName = [string]$Config.adx.tableName
$queryUri = [string]$Config.adx.queryBaseUri
$clusterResourceId = "/subscriptions/$sub/resourceGroups/$clusterRg/providers/Microsoft.Kusto/clusters/$clusterName"
$databaseResourceId = "$clusterResourceId/databases/$databaseName"

$repoRoot = Split-Path $PSScriptRoot -Parent
$webRoot = Join-Path $repoRoot 'activity-story-map\web'
$apiRoot = Join-Path $repoRoot 'activity-story-map\api'

Write-Host 'Activity Story Map deployment plan' -ForegroundColor Cyan
Write-Host "  Resource group:       $resourceGroup"
Write-Host "  Location:             $location"
Write-Host "  Static site storage:  $siteStorageName"
Write-Host "  Function storage:     $functionStorageName"
Write-Host "  Function app:         $functionAppName"
Write-Host "  ADX source:           $clusterName/$databaseName/$tableName"

if ($WhatIf) {
    Write-Host 'WhatIf: no Azure resources will be changed.' -ForegroundColor Yellow
    return
}

foreach ($provider in @('Microsoft.Storage','Microsoft.Web')) {
    az provider register --namespace $provider --wait -o none
}

az group create -n $resourceGroup -l $location -o none | Out-Null

Write-Host 'Ensuring static website storage account...' -NoNewline
$siteStorageExists = az storage account show -g $resourceGroup -n $siteStorageName --query name -o tsv 2>$null
if (-not $siteStorageExists) {
    az storage account create -n $siteStorageName -g $resourceGroup -l $location --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --https-only true -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create storage account '$siteStorageName'." }
}
Write-Host ' OK' -ForegroundColor Green

# Hardened-tenant detection (e.g. MCAPS): a Modify-effect Azure Policy can rewrite
# allowSharedKeyAccess=false at write time. When that happens, account keys are unusable
# and the classic Windows Consumption plan cannot create its file share (403).
$sharedKeyAllowed = az storage account show -g $resourceGroup -n $siteStorageName --query allowSharedKeyAccess -o tsv 2>$null
$hardenedStorage = ($sharedKeyAllowed -eq 'false')
if ($hardenedStorage) {
    Write-Host 'NOTE: subscription policy forces allowSharedKeyAccess=false on storage accounts (hardened tenant).' -ForegroundColor Yellow
    Write-Host '      Switching to Entra ID blob auth and a Flex Consumption Function plan with managed identity.' -ForegroundColor Yellow
}

# The static site is served from the storage $web endpoint and uploaded over the public
# blob endpoint, so the account must accept public network access.
#   MAIN: enable public network access on the site storage (a public website by design).
#         publicNetworkAccess is NOT force-locked the way allowSharedKeyAccess is, so this
#         is permitted even on the hardened tenant.
#   FALLBACK: if a policy hard-locks publicNetworkAccess=Disabled, the public site cannot be
#         served or uploaded from here. Rather than fail the whole step, defer the static
#         front-end (the Function + API still deploy) and surface manual guidance.
$staticSiteDeferred = $false
Write-Host 'Ensuring static-site storage allows public access...' -NoNewline
$siteStorageId = az storage account show -g $resourceGroup -n $siteStorageName --query id -o tsv
Enable-AAMcapsPublicNetworkPolicyExclusion -ResourceId $siteStorageId -TenantDomain ([string]$Config.tenant.domain) | Out-Null
$sitePna = az storage account show -g $resourceGroup -n $siteStorageName --query publicNetworkAccess -o tsv 2>$null
if ($sitePna -ne 'Enabled') {
    az storage account update -g $resourceGroup -n $siteStorageName --public-network-access Enabled --default-action Allow `
        --allow-shared-key-access false --allow-blob-public-access false -o none 2>$null | Out-Null
    Start-Sleep -Seconds 5
    $sitePna = az storage account show -g $resourceGroup -n $siteStorageName --query publicNetworkAccess -o tsv 2>$null
}
if ($sitePna -eq 'Enabled') {
    Write-Host ' OK' -ForegroundColor Green
} else {
    $staticSiteDeferred = $true
    Write-Host ' BLOCKED' -ForegroundColor Red
    Write-Host "  Policy keeps publicNetworkAccess=Disabled on '$siteStorageName'; the public static site cannot be served from here." -ForegroundColor Yellow
    Write-Host '  FALLBACK: deploying the Function + API only. To publish the front-end, either:' -ForegroundColor Yellow
    Write-Host '    1) request a storage public-network-access exception, then rerun Step 8; or' -ForegroundColor Yellow
    Write-Host '    2) host the web/ folder on Azure Static Web Apps / a CDN and point launchUrl there.' -ForegroundColor Yellow
}

if ($hardenedStorage) {
    Write-Host 'Granting Storage Blob Data Contributor to the signed-in user...' -NoNewline
    $operatorId = az ad signed-in-user show --query id -o tsv 2>$null
    if (-not $operatorId) { throw 'Could not resolve the signed-in user objectId for blob RBAC (az ad signed-in-user show failed).' }
    az role assignment create --assignee-object-id $operatorId --assignee-principal-type User --role 'Storage Blob Data Contributor' --scope $siteStorageId -o none 2>$null
    Write-Host ' OK' -ForegroundColor Green

    if (-not $staticSiteDeferred) {
        az storage blob service-properties update --account-name $siteStorageName --auth-mode login --static-website --index-document index.html --404-document index.html -o none | Out-Null
        $uploaded = $false
        # The operator's just-granted Storage Blob Data Contributor role must
        # propagate to the data plane before --auth-mode login works. Data-plane
        # RBAC can take 1-5 min (longer right after a CAE token refresh), so allow
        # up to ~200s (10 x 20s) instead of 90s before giving up.
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            az storage blob upload-batch --account-name $siteStorageName --auth-mode login -s $webRoot -d '$web' --overwrite true -o none 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $uploaded = $true; break }
            Write-Host "  Waiting for blob upload retry (attempt $attempt/10, storage RBAC propagation)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 20
        }
        if (-not $uploaded) { throw "Could not upload the static site to '$siteStorageName' with Entra ID auth. Verify the Storage Blob Data Contributor assignment and that public network access is enabled, then rerun." }
    }
} else {
    if (-not $staticSiteDeferred) {
        $siteKey = az storage account keys list -g $resourceGroup -n $siteStorageName --query '[0].value' -o tsv
        az storage blob service-properties update --account-name $siteStorageName --account-key $siteKey --static-website --index-document index.html --404-document index.html -o none | Out-Null
        az storage blob upload-batch --account-name $siteStorageName --account-key $siteKey -s $webRoot -d '$web' --overwrite true -o none | Out-Null
    }
}
$staticEndpoint = az storage account show -g $resourceGroup -n $siteStorageName --query 'primaryEndpoints.web' -o tsv

Write-Host 'Ensuring Function storage account...' -NoNewline
$functionStorageExists = az storage account show -g $resourceGroup -n $functionStorageName --query name -o tsv 2>$null
if (-not $functionStorageExists) {
    az storage account create -n $functionStorageName -g $resourceGroup -l $location --sku Standard_LRS --kind StorageV2 --https-only true -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create storage account '$functionStorageName'." }
}
Write-Host ' OK' -ForegroundColor Green
$functionStorageId = az storage account show -g $resourceGroup -n $functionStorageName --query id -o tsv
$visitContainerOutput = az storage container-rm create -g $resourceGroup --storage-account $functionStorageName `
    -n activity-story-map --public-access off -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not ensure the Story Map visit-state container: $(($visitContainerOutput | Out-String).Trim())"
}
if (Test-AAMcapsHardenedTenant -Domain ([string]$Config.tenant.domain)) {
    Enable-AAMcapsPublicNetworkPolicyExclusion -ResourceId $functionStorageId -TenantDomain ([string]$Config.tenant.domain) | Out-Null
    az storage account update -g $resourceGroup -n $functionStorageName --public-network-access Enabled --default-action Allow `
        --allow-shared-key-access false --allow-blob-public-access false -o none 2>$null | Out-Null
}

$normalizedLocation = ($location -replace '\s', '').ToLowerInvariant()
$useFlex = $false
$functionExists = az functionapp show -g $resourceGroup -n $functionAppName --query name -o tsv 2>$null
if (-not $functionExists) {
    # Plan selection: Windows Consumption by default; Flex Consumption + managed identity
    # when shared-key access is policy-blocked or the Dynamic SKU has no quota in this region.
    if ($hardenedStorage) {
        $useFlex = $true
    } else {
        # Preflight: is the Consumption (Dynamic) SKU open in this region for this subscription?
        $dynamicRegions = @()
        try {
            $geo = Invoke-AzRestJson -Method GET -Url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Web/geoRegions?sku=Dynamic&api-version=2023-12-01"
            $dynamicRegions = @($geo.value | ForEach-Object { ([string]$_.name -replace '\s', '').ToLowerInvariant() })
        } catch { $dynamicRegions = @() }
        if ($dynamicRegions.Count -gt 0 -and ($dynamicRegions -notcontains $normalizedLocation)) {
            Write-Host "NOTE: Consumption (Dynamic) plan is not available in '$location' for this subscription. Falling back to Flex Consumption." -ForegroundColor Yellow
            $useFlex = $true
        }
    }
    if ($useFlex) {
        # Preflight: Flex Consumption regional availability (avoids a mid-deploy failure).
        $flexRegions = @(az functionapp list-flexconsumption-locations --query '[].name' -o tsv 2>$null | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
        if ($flexRegions.Count -gt 0 -and ($flexRegions -notcontains $normalizedLocation)) {
            throw "Flex Consumption is not available in '$location' and the classic Consumption plan cannot be used here (shared-key access blocked or Dynamic quota unavailable). Redeploy in a Flex-enabled region: az functionapp list-flexconsumption-locations"
        }
    }
    $planLabel = if ($useFlex) { 'Flex Consumption + managed identity' } else { 'Windows Consumption' }
    Write-Host "Creating Function App ($planLabel)..." -NoNewline
    if ($useFlex) {
        az functionapp create `
            --resource-group $resourceGroup `
            --name $functionAppName `
            --storage-account $functionStorageName `
            --flexconsumption-location $location `
            --runtime node `
            --runtime-version 20 `
            --deployment-storage-auth-type SystemAssignedIdentity `
            -o none | Out-Null
    } else {
        az functionapp create `
            --resource-group $resourceGroup `
            --name $functionAppName `
            --storage-account $functionStorageName `
            --consumption-plan-location $location `
            --runtime node `
            --runtime-version 24 `
            --functions-version 4 `
            --os-type Windows `
            -o none | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to create Function App '$functionAppName'." }
    Write-Host ' OK' -ForegroundColor Green
} else {
    Write-Host "Function App exists: $functionAppName" -ForegroundColor DarkYellow
    # Flex Consumption apps do NOT expose appServicePlanId / sku.tier, so the classic
    # plan lookup returns nothing and would leave $useFlex = $false. Detect Flex from the
    # app 'kind' instead: this module always creates Flex as linux ('functionapp,linux')
    # and classic Consumption as Windows ('functionapp').
    $existingKind = az functionapp show -g $resourceGroup -n $functionAppName --query kind -o tsv 2>$null
    if ($existingKind -and $existingKind -match 'linux') {
        $useFlex = $true
    } else {
        $existingPlanId = az functionapp show -g $resourceGroup -n $functionAppName --query appServicePlanId -o tsv 2>$null
        if ($existingPlanId) {
            $existingPlanTier = az appservice plan show --ids $existingPlanId --query sku.tier -o tsv 2>$null
            $useFlex = ($existingPlanTier -eq 'FlexConsumption')
        }
    }
}

$identity = az functionapp identity assign -g $resourceGroup -n $functionAppName -o json | ConvertFrom-Json
$principalId = [string]$identity.principalId
if (-not $principalId) {
    $principalId = az functionapp identity show -g $resourceGroup -n $functionAppName --query principalId -o tsv
}
if (-not $principalId) { throw "Could not resolve managed identity principal id for '$functionAppName'." }

# Flex package deployment always uses the function identity; hardened host
# storage additionally requires Queue and Table access.
if ($useFlex -or $hardenedStorage) {
    $storageRoles = @('Storage Blob Data Owner')
    if ($hardenedStorage) {
        $storageRoles += 'Storage Queue Data Contributor', 'Storage Table Data Contributor'
    }
    foreach ($role in $storageRoles) {
        az role assignment create --role $role --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $functionStorageId -o none 2>$null
    }
}

if ($hardenedStorage) {
    # 'az functionapp create' wires AzureWebJobsStorage as a KEY-BASED connection
    # string. With allowSharedKeyAccess=false the runtime cannot read host keys
    # ('Failed to fetch host key') and every zip deploy health check fails.
    # Switch the host storage to identity-based access: grant the app MI the
    # data-plane roles, set AzureWebJobsStorage__accountName, drop the key string.
    Write-Host 'Configuring identity-based host storage (hardened tenant)...' -NoNewline
    az functionapp config appsettings set -g $resourceGroup -n $functionAppName --settings "AzureWebJobsStorage__accountName=$functionStorageName" -o none 2>$null | Out-Null
    az functionapp config appsettings delete -g $resourceGroup -n $functionAppName --setting-names AzureWebJobsStorage -o none 2>$null | Out-Null
    Write-Host ' OK' -ForegroundColor Green
}

$appSettings = @(
    "ADX_QUERY_URI=$queryUri"
    "ADX_DATABASE=$databaseName"
    "ADX_TABLE=$tableName"
)
if (-not $useFlex) {
    # WEBSITE_RUN_FROM_PACKAGE is not supported on Flex Consumption (deployment uses the MI-backed deployment container).
    $appSettings += 'WEBSITE_RUN_FROM_PACKAGE=1'
} else {
    # Flex rejects WEBSITE_RUN_FROM_PACKAGE at zip-deploy time ('not supported with this SKU').
    # A prior classic-style run (or config-zip auto-set) may have left it behind: drop it.
    az functionapp config appsettings delete -g $resourceGroup -n $functionAppName --setting-names WEBSITE_RUN_FROM_PACKAGE -o none 2>$null | Out-Null
}
az functionapp config appsettings set -g $resourceGroup -n $functionAppName --settings $appSettings -o none | Out-Null

$staticOrigin = $staticEndpoint.TrimEnd('/')
az functionapp cors add -g $resourceGroup -n $functionAppName --allowed-origins $staticEndpoint -o none 2>$null | Out-Null
az functionapp cors add -g $resourceGroup -n $functionAppName --allowed-origins $staticOrigin -o none 2>$null | Out-Null

Write-Host 'Granting ADX database Viewer to Function identity...' -NoNewline
$assignmentName = "storymap-viewer-$($principalId.Replace('-', ''))"
$assignmentUrl = "https://management.azure.com${databaseResourceId}/principalAssignments/${assignmentName}?api-version=2023-08-15"
$assignmentBody = @{
    properties = @{
        principalId = $principalId
        principalType = 'App'
        role = 'Viewer'
        tenantId = $tenantId
    }
}
try {
    Invoke-AzRestJson -Method PUT -Url $assignmentUrl -Body $assignmentBody | Out-Null
    Write-Host ' OK' -ForegroundColor Green
} catch {
    # Idempotent re-run: Kusto stores the assignment under a dash-stripped name
    # and rejects a second one for the same principal+role with a 400. An older
    # run may have created 'storymapviewer<id>' while we request
    # 'storymap-viewer-<id>'. Same effective grant -> treat as success.
    $adxErr = [string]$_.Exception.Message
    try {
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $adxErr += ' ' + [string]$_.ErrorDetails.Message }
        elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Message) { $adxErr += ' ' + [string]$_.Exception.InnerException.Message }
    } catch {}
    if ($adxErr -match 'already exists with the same role and principal') {
        Write-Host ' OK (already assigned)' -ForegroundColor Green
    } else {
        Write-Host ' FAIL' -ForegroundColor Red
        throw
    }
}

$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "activity-story-map-api-$suffix.zip"
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $apiRoot '*') -DestinationPath $zipPath -Force
# Flex Consumption deploys through the deployment-storage container on the FUNCTION
# storage account, accessed by the app's managed identity. On a hardened tenant that
# account is created with publicNetworkAccess=Disabled, so the Kudu/Legion pipeline
# gets 403 (InaccessibleStorageException / BlobUploadFailedException) regardless of
# RBAC. Enable public network access on the function storage before deploying (mirrors
# the static-site storage handling above).
if ($useFlex) {
    $fnPna = az storage account show -g $resourceGroup -n $functionStorageName --query publicNetworkAccess -o tsv 2>$null
    if ($fnPna -ne 'Enabled') {
        Write-Host 'Enabling public network access on Function storage (Flex deployment container)...' -NoNewline
        az storage account update -g $resourceGroup -n $functionStorageName --public-network-access Enabled --default-action Allow -o none 2>$null | Out-Null
        Start-Sleep -Seconds 15
        Write-Host ' OK' -ForegroundColor Green
    }
}
# Flex: deployment-container MI access and (hardened) host-storage RBAC can take
# minutes to propagate. Deploy through Kudu OneDeploy with an App Service audience
# Entra token, matching the Azure CLI Flex deployment flow.
$deployAttempts = if ($useFlex) { 5 } else { 1 }
$deployed = $false
$lastDeployError = ''
for ($attempt = 1; $attempt -le $deployAttempts; $attempt++) {
    if ($useFlex) {
        try {
            Write-Host '  Deploying Flex package with Kudu OneDeploy and Entra authentication...' -ForegroundColor DarkYellow
            Invoke-AAFunctionOneDeploy -FunctionAppName $functionAppName -ZipPath $zipPath
            Write-Host '  Flex package deployed.' -ForegroundColor Green
            $deployed = $true
            break
        } catch {
            $lastDeployError = $_.Exception.Message
        }
    } else {
        $zipOutput = & az functionapp deployment source config-zip -g $resourceGroup -n $functionAppName --src $zipPath -o none 2>&1
        if ($LASTEXITCODE -eq 0) {
            $deployed = $true
            break
        }
        $lastDeployError = ($zipOutput | Out-String).Trim()
    }

    if ($attempt -lt $deployAttempts) {
        Write-Host "  Zip deploy retry $attempt/$deployAttempts (waiting for storage RBAC propagation)..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 45
    }
}
if (-not $deployed) {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    throw "Deployment to '$functionAppName' failed after $deployAttempts attempt(s): $lastDeployError"
}
Remove-Item -LiteralPath $zipPath -Force

$functionHost = ''
for ($attempt = 1; $attempt -le 20; $attempt++) {
    $functionDetailsJson = az functionapp show -g $resourceGroup -n $functionAppName -o json 2>$null
    if ($functionDetailsJson) {
        $functionDetails = $functionDetailsJson | ConvertFrom-Json
        $functionHost = [string]$functionDetails.properties.defaultHostName
        if (-not $functionHost) { $functionHost = [string]$functionDetails.defaultHostName }
    }
    if ($functionHost) { break }
    Start-Sleep -Seconds 15
}
if (-not $functionHost) {
    throw "Function App '$functionAppName' did not expose a default hostname after deployment."
}

$httpsUpdateOutput = az resource update -g $resourceGroup -n $functionAppName `
    --resource-type Microsoft.Web/sites --set properties.httpsOnly=true -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not enable HTTPS-only on '$functionAppName': $(($httpsUpdateOutput | Out-String).Trim())"
}
$apiBaseUrl = "https://$functionHost"
$launchUrl = if ($staticSiteDeferred) { $apiBaseUrl } else { "$($staticEndpoint)?api=$apiBaseUrl" }

if (-not $staticSiteDeferred) {
    $runtimeConfigPath = Join-Path ([System.IO.Path]::GetTempPath()) "activity-story-map-config-$suffix.js"
    try {
        [System.IO.File]::WriteAllText($runtimeConfigPath, "window.ACTIVITY_API_BASE = `"$apiBaseUrl`";`n")
        az storage blob upload --account-name $siteStorageName --auth-mode login --container-name '$web' `
            --name 'config.js' --file $runtimeConfigPath --overwrite true -o none 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not publish the runtime API configuration to '$siteStorageName'." }
    } finally {
        Remove-Item -LiteralPath $runtimeConfigPath -Force -ErrorAction SilentlyContinue
    }
}

$apiProbePaths = @('/api/graph?hours=1', '/api/visits')
foreach ($probePath in $apiProbePaths) {
    $apiReady = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $probe = Invoke-WebRequest -Uri "$apiBaseUrl$probePath" -TimeoutSec 120 -ErrorAction Stop
            if ($probe.StatusCode -eq 200) {
                $apiReady = $true
                break
            }
        } catch {
            if ($attempt -lt 10) { Start-Sleep -Seconds 15 }
        }
    }
    if (-not $apiReady) {
        throw "Function App '$functionAppName' was deployed but '$apiBaseUrl$probePath' did not become healthy."
    }
}

$storyMapConfig = [ordered]@{
    enabled = $true
    staticSiteDeferred = $staticSiteDeferred
    resourceGroup = $resourceGroup
    location = $location
    hostingPlan = $(if ($useFlex) { 'FlexConsumption' } else { 'WindowsConsumption' })
    storageAccountName = $siteStorageName
    functionStorageAccountName = $functionStorageName
    functionAppName = $functionAppName
    functionPrincipalId = $principalId
    staticWebsiteUrl = $staticEndpoint
    apiBaseUrl = $apiBaseUrl
    launchUrl = $launchUrl
    defaultLookbackHours = 24
    source = [ordered]@{
        clusterName = $clusterName
        databaseName = $databaseName
        tableName = $tableName
    }
}

if (Test-Path $ConfigPath) {
    $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    Set-AAObjectProperty -Object $rawConfig -Name 'activityStoryMap' -Value $storyMapConfig
    $rawConfig | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
}

if (Test-Path $InstallationDefinitionsPath) {
    $defs = Get-Content -LiteralPath $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
    Set-AAObjectProperty -Object $defs -Name 'activityStoryMap' -Value $storyMapConfig
    if (-not $defs.steps) { Set-AAObjectProperty -Object $defs -Name 'steps' -Value ([PSCustomObject][ordered]@{}) }
    $step8 = [ordered]@{
        activity = 'Activity Story Map'
        completedAt = (Get-Date).ToString('o')
        dryRun = $false
        staticWebsiteUrl = $staticEndpoint
        apiBaseUrl = $apiBaseUrl
        launchUrl = $launchUrl
        functionAppName = $functionAppName
        storageAccountName = $siteStorageName
    }
    $existingStep = $defs.steps.PSObject.Properties['8']
    if ($existingStep) { $existingStep.Value = $step8 }
    else { $defs.steps.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new('8', $step8)) }
    $defs.updatedAt = (Get-Date).ToString('o')
    $defs | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $InstallationDefinitionsPath -Encoding utf8
}

Write-Host ''
if ($staticSiteDeferred) {
    Write-Host 'Activity Story Map: Function + API deployed; static front-end DEFERRED (storage public access blocked).' -ForegroundColor Yellow
    Write-Host "  API: $apiBaseUrl/api/graph" -ForegroundColor Yellow
    Write-Host '  Enable public network access on the site storage (or host web/ on Static Web Apps), then rerun Step 8.' -ForegroundColor Yellow
} else {
    Write-Host 'Activity Story Map deployed.' -ForegroundColor Green
}
Write-Host "  UI:  $staticEndpoint"
Write-Host "  API: $apiBaseUrl/api/graph"
Write-Host "  Open with API binding: $launchUrl"

# MCAPS hardened-tenant fallback (replicates Tenant A's Invoke-MorningFix model).
# On MngEnvMCAP* tenants a nightly Modify-effect Azure Policy flips storage / Key
# Vault / Azure OpenAI / Automation / ADX publicNetworkAccess back to Disabled,
# which would take the public $web static site (and the data plane) offline every
# night. For these tenants we auto-deploy the bundled daily reachability runbook
# (tools\Restore-LabPublicNetworkAccess.ps1) so the lab self-heals each morning.
# Public / non-hardened tenants are intentionally left untouched (no surprise
# Automation-MI Contributor grant); they still get the manual recommendation
# banner from the wizard's standard hardening flow.
if (Test-AAMcapsHardenedTenant -Domain ([string]$Config.tenant.domain)) {
    Write-Host ''
    Write-Host 'MCAPS hardened tenant detected (MngEnvMCAP* domain).' -ForegroundColor Yellow
    Write-Host '  Ensuring the daily reachability runbook is deployed so the static site survives nightly hardening...' -ForegroundColor Yellow

    $aaName = $null
    $aaCandidate = [string]$Config.infrastructure.automationAccountName
    if ($aaCandidate) {
        $aaExists = az automation account show -n $aaCandidate -g $resourceGroup --query name -o tsv 2>$null
        if ($aaExists) { $aaName = $aaCandidate }
    }
    if (-not $aaName) {
        $aaFound = az resource list -g $resourceGroup --resource-type Microsoft.Automation/automationAccounts --query '[].name' -o tsv 2>$null
        $aaList = @(($aaFound -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($aaList.Count -eq 1) { $aaName = $aaList[0] }
    }

    $deployer = Join-Path $repoRoot 'tools\Deploy-LabReachabilityRunbook.ps1'
    if (-not $aaName) {
        Write-Host '  [SKIP] Could not resolve a single Automation Account in the resource group.' -ForegroundColor Yellow
        Write-Host "         Deploy the fallback manually: .\tools\Deploy-LabReachabilityRunbook.ps1 -ResourceGroup $resourceGroup -AutomationAccountName <aa-name>" -ForegroundColor Yellow
    } elseif (-not (Test-Path -LiteralPath $deployer)) {
        Write-Host "  [SKIP] Reachability deployer not found at $deployer." -ForegroundColor Yellow
    } else {
        try {
            & $deployer -ResourceGroup $resourceGroup -AutomationAccountName $aaName
            Write-Host "  [OK] Daily reachability runbook ensured on '$aaName' (re-enables storage/KV/OAI/Automation/ADX public access each morning)." -ForegroundColor Green
        } catch {
            Write-Host "  [WARN] Could not auto-deploy the reachability runbook: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "         Deploy it manually: .\tools\Deploy-LabReachabilityRunbook.ps1 -ResourceGroup $resourceGroup -AutomationAccountName $aaName" -ForegroundColor Yellow
        }
    }
}

return [PSCustomObject]$storyMapConfig
