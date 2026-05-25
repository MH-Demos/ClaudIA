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
    az storage account create -n $siteStorageName -g $resourceGroup -l $location --sku Standard_LRS --kind StorageV2 --allow-blob-public-access true --https-only true -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create storage account '$siteStorageName'." }
}
Write-Host ' OK' -ForegroundColor Green

$siteKey = az storage account keys list -g $resourceGroup -n $siteStorageName --query '[0].value' -o tsv
az storage blob service-properties update --account-name $siteStorageName --account-key $siteKey --static-website --index-document index.html --404-document index.html -o none | Out-Null
az storage blob upload-batch --account-name $siteStorageName --account-key $siteKey -s $webRoot -d '$web' --overwrite true -o none | Out-Null
$staticEndpoint = az storage account show -g $resourceGroup -n $siteStorageName --query 'primaryEndpoints.web' -o tsv

Write-Host 'Ensuring Function storage account...' -NoNewline
$functionStorageExists = az storage account show -g $resourceGroup -n $functionStorageName --query name -o tsv 2>$null
if (-not $functionStorageExists) {
    az storage account create -n $functionStorageName -g $resourceGroup -l $location --sku Standard_LRS --kind StorageV2 --https-only true -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create storage account '$functionStorageName'." }
}
Write-Host ' OK' -ForegroundColor Green

$functionExists = az functionapp show -g $resourceGroup -n $functionAppName --query name -o tsv 2>$null
if (-not $functionExists) {
    Write-Host 'Creating Function App...' -NoNewline
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
    if ($LASTEXITCODE -ne 0) { throw "Failed to create Function App '$functionAppName'." }
    Write-Host ' OK' -ForegroundColor Green
} else {
    Write-Host "Function App exists: $functionAppName" -ForegroundColor DarkYellow
}

$identity = az functionapp identity assign -g $resourceGroup -n $functionAppName -o json | ConvertFrom-Json
$principalId = [string]$identity.principalId
if (-not $principalId) {
    $principalId = az functionapp identity show -g $resourceGroup -n $functionAppName --query principalId -o tsv
}
if (-not $principalId) { throw "Could not resolve managed identity principal id for '$functionAppName'." }

az functionapp config appsettings set -g $resourceGroup -n $functionAppName --settings `
    "ADX_QUERY_URI=$queryUri" `
    "ADX_DATABASE=$databaseName" `
    "ADX_TABLE=$tableName" `
    "WEBSITE_RUN_FROM_PACKAGE=1" `
    -o none | Out-Null

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
Invoke-AzRestJson -Method PUT -Url $assignmentUrl -Body $assignmentBody | Out-Null
Write-Host ' OK' -ForegroundColor Green

$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "activity-story-map-api-$suffix.zip"
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $apiRoot '*') -DestinationPath $zipPath -Force
az functionapp deployment source config-zip -g $resourceGroup -n $functionAppName --src $zipPath -o none | Out-Null
Remove-Item -LiteralPath $zipPath -Force

$functionHost = az functionapp show -g $resourceGroup -n $functionAppName --query defaultHostName -o tsv
$apiBaseUrl = "https://$functionHost"
$launchUrl = "$($staticEndpoint)?api=$apiBaseUrl"

$storyMapConfig = [ordered]@{
    enabled = $true
    resourceGroup = $resourceGroup
    location = $location
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
Write-Host 'Activity Story Map deployed.' -ForegroundColor Green
Write-Host "  UI:  $staticEndpoint"
Write-Host "  API: $apiBaseUrl/api/graph"
Write-Host "  Open with API binding: $launchUrl"

return [PSCustomObject]$storyMapConfig
