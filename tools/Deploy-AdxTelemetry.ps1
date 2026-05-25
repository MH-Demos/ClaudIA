<#
.SYNOPSIS
    Deploy Azure Data Explorer telemetry resources for autonomous agent activity.
.DESCRIPTION
    Creates an ADX cluster, an ADX database, the agent activity table, JSON
    ingestion mapping, streaming ingestion policy, and a Database Ingestor
    principal assignment for the configured application.

    The script reads and updates config/Installation_definitions.json by default.
    It is idempotent and can be run again after the cluster finishes provisioning.
.EXAMPLE
    .\tools\Deploy-AdxTelemetry.ps1 -WhatIf
.EXAMPLE
    .\tools\Deploy-AdxTelemetry.ps1
#>
param(
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$ClientSecretName = 'agent-client-secret',
    [string]$M365Scope = 'https://manage.office.com/.default',
    [string]$PreferredSku = 'Dev(No SLA)_Standard_E2a_v4',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Invoke-AzRestJson {
    param(
        [Parameter(Mandatory)] [ValidateSet('GET','PUT','POST')] [string]$Method,
        [Parameter(Mandatory)] [string]$Url,
        $Body,
        [switch]$AllowNotFound
    )

    $bodyPath = $null
    $errPath = $null
    $oldNativeErrorPreference = $null
    $hasNativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    try {
        if ($hasNativeErrorPreference) {
            $oldNativeErrorPreference = $Global:PSNativeCommandUseErrorActionPreference
            $Global:PSNativeCommandUseErrorActionPreference = $false
        }
        $errPath = Join-Path ([System.IO.Path]::GetTempPath()) "adx-arm-error-$([guid]::NewGuid()).txt"
        $args = @('rest', '--method', $Method, '--url', $Url, '--output', 'json')
        if ($Body) {
            $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "adx-arm-body-$([guid]::NewGuid()).json"
            $Body | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $bodyPath -Encoding utf8
            $args += @('--headers', 'Content-Type=application/json', '--body', "@$bodyPath")
        }

        $raw = & az @args 2> $errPath
        if ($LASTEXITCODE -ne 0) {
            $err = if (Test-Path $errPath) { Get-Content -Path $errPath -Raw } else { '' }
            if ($AllowNotFound -and $err -match 'Not Found|ResourceNotFound|ParentResourceNotFound|Cannot fetch databases while resource is in state') {
                return $null
            }
            throw "az rest failed: $Method $Url`n$err"
        }
        if ($raw) { return $raw | ConvertFrom-Json }
        return $null
    }
    finally {
        if ($hasNativeErrorPreference) {
            $Global:PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
        }
        if ($bodyPath -and (Test-Path $bodyPath)) { Remove-Item -LiteralPath $bodyPath -Force }
        if ($errPath -and (Test-Path $errPath)) { Remove-Item -LiteralPath $errPath -Force }
    }
}

function Get-DomainCode {
    param([Parameter(Mandatory)] [string]$Domain)
    $label = ($Domain -split '\.')[0]
    $code = ($label -replace '[^a-zA-Z0-9]', '').ToUpperInvariant()
    if (-not $code) { throw "Cannot derive ADX code from domain '$Domain'." }
    return $code
}

function New-AdxClusterName {
    param([Parameter(Mandatory)] [string]$DomainCode)
    $base = "adx-$($DomainCode.ToLowerInvariant())"
    if ($base.Length -gt 15) { $base = $base.Substring(0, 15).TrimEnd('-') }
    return "$base$(Get-Random -Minimum 1000 -Maximum 9999)"
}

function Get-AdxSku {
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$Preferred
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Kusto/locations/$Location/skus?api-version=2023-08-15"
    $skus = @()
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $skus = @((Invoke-AzRestJson -Method GET -Url $url).value | Where-Object { $_.resourceType -eq 'clusters' })
            break
        } catch {
            $message = $_.Exception.Message
            if ($message -notmatch 'InternalServerError|Internal Server Error|TooManyRequests|ServiceUnavailable' -or $attempt -eq 5) {
                Write-Host "  [WARN] Could not list ADX SKUs for '$Location'. Falling back to configured SKU '$Preferred'." -ForegroundColor Yellow
                return [PSCustomObject]@{
                    name = $Preferred
                    tier = 'Basic'
                    resourceType = 'clusters'
                }
            }
            Write-Host "  [WAIT] ADX SKU list failed transiently (attempt $attempt/5). Retrying..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds ([Math]::Min(10 * $attempt, 30))
        }
    }

    $preferredMatch = $skus | Where-Object { $_.name -eq $Preferred } | Select-Object -First 1
    if ($preferredMatch) { return $preferredMatch }

    $devMatch = $skus | Where-Object { $_.name -like 'Dev(No SLA)*' } | Select-Object -First 1
    if ($devMatch) { return $devMatch }

    throw "No Dev(No SLA) ADX SKU is available in '$Location'."
}

function Wait-ProviderRegistration {
    param([Parameter(Mandatory)] [string]$SubscriptionId)

    $providerUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Kusto?api-version=2021-04-01"
    $state = (Invoke-AzRestJson -Method GET -Url $providerUrl).registrationState
    if ($state -eq 'Registered') { return }

    Write-Host "Registering provider Microsoft.Kusto..." -ForegroundColor Yellow
    Invoke-AzRestJson -Method POST -Url "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Kusto/register?api-version=2021-04-01" | Out-Null
    do {
        Start-Sleep -Seconds 10
        $state = (Invoke-AzRestJson -Method GET -Url $providerUrl).registrationState
        Write-Host "  Microsoft.Kusto: $state"
    } while ($state -ne 'Registered')
}

function Wait-KustoResourceSucceeded {
    param(
        [Parameter(Mandatory)] [string]$ResourceId,
        [Parameter(Mandatory)] [string]$ResourceName,
        [int]$TimeoutMinutes = 30
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $url = "https://management.azure.com${ResourceId}?api-version=2023-08-15"
    do {
        try {
            $resource = Invoke-AzRestJson -Method GET -Url $url -AllowNotFound
            if (-not $resource) {
                Write-Host "  ${ResourceName}: not found yet"
                Start-Sleep -Seconds 30
                continue
            }
            $state = $resource.properties.provisioningState
            if (-not $state) { $state = $resource.properties.state }
            if ($state -eq 'Succeeded') { return $resource }
            if ($state -in @('Failed', 'Canceled')) {
                throw "$ResourceName provisioning ended with state '$state'."
            }
            Write-Host "  ${ResourceName}: $state"
        } catch {
            if ($_.Exception.Message -match 'Cannot fetch databases while resource is in state') {
                Write-Host "  ${ResourceName}: parent still creating"
            } else {
                throw
            }
        }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $ResourceName to reach Succeeded."
}

function Invoke-KustoManagementCommand {
    param(
        [Parameter(Mandatory)] [string]$ClusterUri,
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string]$Command
    )

    $token = & az account get-access-token --resource 'https://kusto.kusto.windows.net' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Unable to get Kusto access token.' }

    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method POST -Uri "$ClusterUri/v1/rest/mgmt" -Headers $headers -Body $body | Out-Null
}

function Escape-KustoName {
    param([Parameter(Mandatory)] [string]$Name)
    return $Name.Replace("'", "''")
}

function Set-KeyVaultSecretValue {
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$SecretName,
        [Parameter(Mandatory)] [string]$SecretValue
    )

    & az keyvault secret set --vault-name $VaultName --name $SecretName --value $SecretValue -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to store Key Vault secret '$SecretName' in vault '$VaultName'." }
}

function Invoke-AzRestJsonIdempotentPut {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] $Body,
        [Parameter(Mandatory)] [string]$AlreadyExistsPattern
    )

    try {
        Invoke-AzRestJson -Method PUT -Url $Url -Body $Body | Out-Null
        return $true
    } catch {
        if ($_.Exception.Message -match $AlreadyExistsPattern) {
            return $false
        }
        throw
    }
}

function Update-InstallationDefinitions {
    param(
        [Parameter(Mandatory)] $Definitions,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $AdxConfig
    )

    if ($Definitions.PSObject.Properties['adx']) {
        $Definitions.adx = $AdxConfig
    } else {
        $Definitions | Add-Member -NotePropertyName adx -NotePropertyValue $AdxConfig -Force
    }
    if ($Definitions.steps -and $Definitions.steps.PSObject.Properties['4'] -and $Definitions.steps.'4') {
        if ($Definitions.steps.'4'.PSObject.Properties['adx']) {
            $Definitions.steps.'4'.adx = $AdxConfig
        } else {
            $Definitions.steps.'4' | Add-Member -NotePropertyName adx -NotePropertyValue $AdxConfig -Force
        }
    }
    $Definitions.updatedAt = (Get-Date).ToString('o')
    $Definitions | ConvertTo-Json -Depth 40 | Set-Content -Path $Path -Encoding utf8
}

function Sync-SourceConfigAdx {
    param(
        [Parameter(Mandatory)] [string]$DefinitionsPath,
        [Parameter(Mandatory)] $Definitions,
        [Parameter(Mandatory)] $AdxConfig
    )

    $configPath = if ($Definitions.sourceConfigPath) {
        [string]$Definitions.sourceConfigPath
    } else {
        Join-Path (Split-Path -Parent $DefinitionsPath) 'agents.json'
    }
    if (-not (Test-Path $configPath)) { return }

    $config = Get-Content -Path $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($config.PSObject.Properties['adx']) {
        $config.adx = $AdxConfig
    } else {
        $config | Add-Member -NotePropertyName adx -NotePropertyValue $AdxConfig -Force
    }
    $config | ConvertTo-Json -Depth 50 | Set-Content -Path $configPath -Encoding utf8
}

function Get-FirstValue {
    param([object[]]$Values)

    foreach ($value in $Values) {
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }
    return $null
}

function Get-SourceConfig {
    param([Parameter(Mandatory)] [string]$DefinitionsPath, $Definitions)

    $configCandidates = @()
    if ($Definitions.sourceConfigPath) { $configCandidates += [string]$Definitions.sourceConfigPath }
    $configCandidates += (Join-Path (Split-Path -Parent $DefinitionsPath) 'agents.json')

    foreach ($candidate in $configCandidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path $candidate)) {
            return Get-Content -Path $candidate -Raw -Encoding utf8 | ConvertFrom-Json
        }
    }
    return $null
}

if (-not (Test-Path $InstallationDefinitionsPath)) {
    throw "Installation definitions file not found: $InstallationDefinitionsPath"
}

$defs = Get-Content -Path $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
$sourceConfig = Get-SourceConfig -DefinitionsPath $InstallationDefinitionsPath -Definitions $defs
$step4Adx = $null
if ($defs.steps -and $defs.steps.PSObject.Properties['4'] -and $defs.steps.'4'.adx) {
    $step4Adx = $defs.steps.'4'.adx
}
$sourceAdx = if ($defs.adx) { $defs.adx } elseif ($step4Adx) { $step4Adx } elseif ($sourceConfig -and $sourceConfig.adx) { $sourceConfig.adx } else { $null }

$subscriptionId = $defs.tenant.subscriptionId
$location = $defs.tenant.location
$resourceGroup = $defs.infrastructure.resourceGroup
$keyVaultName = $defs.infrastructure.keyVaultName
$domainCode = Get-DomainCode -Domain $defs.tenant.domain

if (-not $TenantId) {
    $activeTenantId = & az account show --query tenantId -o tsv 2>$null
    $TenantId = Get-FirstValue @(
        $defs.tenant.tenantId,
        $sourceConfig.tenant.tenantId,
        $activeTenantId,
        $sourceAdx.tenantId
    )
}
if (-not $TenantId) {
    $TenantId = & az account show --query tenantId -o tsv 2>$null
}
if (-not $ClientId) {
    $ClientId = Get-FirstValue @(
        $defs.steps.'3'.appId,
        $sourceAdx.clientId
    )
}
if (-not $ClientSecretName -and $sourceAdx.clientSecretName) { $ClientSecretName = $sourceAdx.clientSecretName }
if (-not $ClientSecret) { $ClientSecret = $sourceAdx.clientSecret }
if (-not $M365Scope -and $sourceAdx.m365Scope) { $M365Scope = $sourceAdx.m365Scope }

if (-not $TenantId) { throw 'TenantId is required. Pass -TenantId or set adx.tenantId in Installation_definitions.json or config/agents.json.' }
if (-not $ClientId) { throw 'ClientId is required. Pass -ClientId or set adx.clientId in Installation_definitions.json or config/agents.json.' }
if (-not $keyVaultName) { throw 'infrastructure.keyVaultName is required to store the ADX client secret.' }
if (-not $ClientSecretName) { throw 'ClientSecretName is required.' }

$existingClusterName = $sourceAdx.clusterName
$clusterName = if ($existingClusterName) { $existingClusterName } else { New-AdxClusterName -DomainCode $domainCode }
$databaseName = if ($sourceAdx.databaseName) { $sourceAdx.databaseName } else { "ADX-$domainCode" }
$tableName = if ($sourceAdx.tableName) { $sourceAdx.tableName } else { "${domainCode}_AgentActivity" }
$mappingName = if ($sourceAdx.mappingName) { $sourceAdx.mappingName } else { "${tableName}_mapping" }
$clusterUri = "https://$clusterName.$location.kusto.windows.net"
$clusterResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Kusto/clusters/$clusterName"
$databaseResourceId = "$clusterResourceId/databases/$databaseName"
$assignmentName = "database-ingestor-$($ClientId.Replace('-', ''))"
$currentUserObjectId = & az ad signed-in-user show --query id -o tsv 2>$null
$currentUserAdminAssignmentName = if ($currentUserObjectId) { "database-admin-$($currentUserObjectId.Replace('-', ''))" } else { $null }

$sku = Get-AdxSku -SubscriptionId $subscriptionId -Location $location -Preferred $PreferredSku

$adxConfig = [ordered]@{
    enabled = $true
    tenantId = $TenantId
    clientId = $ClientId
    clientSecretName = $ClientSecretName
    keyVaultName = $keyVaultName
    m365Scope = $M365Scope
    resourceGroup = $resourceGroup
    location = $location
    clusterName = $clusterName
    clusterSku = $sku.name
    clusterTier = $sku.tier
    streamingIngestion = $true
    enablePurge = $false
    autoStopCluster = $false
    publicNetworkAccess = 'Enabled'
    ingestBaseUri = $clusterUri
    queryBaseUri = $clusterUri
    databaseName = $databaseName
    tableName = $tableName
    mappingName = $mappingName
    retentionInDays = 365
    ingestorPrincipalId = $ClientId
    ingestorPrincipalType = 'App'
    ingestorRole = 'Ingestor'
}

Write-Host "ADX telemetry deployment plan" -ForegroundColor Cyan
Write-Host "  Resource group: $resourceGroup"
Write-Host "  Location:       $location"
Write-Host "  Cluster:        $clusterName"
Write-Host "  SKU:            $($sku.name) / $($sku.tier)"
Write-Host "  Database:       $databaseName"
Write-Host "  Table:          $tableName"
Write-Host "  Key Vault:      $keyVaultName/$ClientSecretName"
Write-Host "  Tenant ID:      $TenantId"
Write-Host "  Client ID:      $ClientId"
Write-Host "  Principal role: Database Ingestor"

if ($WhatIf) {
    Write-Host ""
    Write-Host "WhatIf: updating no Azure resources and no config file." -ForegroundColor Yellow
    return
}

$preflightConfig = [ordered]@{}
foreach ($entry in $adxConfig.GetEnumerator()) { $preflightConfig[$entry.Key] = $entry.Value }
Update-InstallationDefinitions -Definitions $defs -Path $InstallationDefinitionsPath -AdxConfig $preflightConfig

Wait-ProviderRegistration -SubscriptionId $subscriptionId

Write-Host "Ensuring resource group..." -NoNewline
$existingRgLocation = & az group show -n $resourceGroup --query location -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existingRgLocation) {
    Write-Host " EXISTS ($existingRgLocation)" -ForegroundColor DarkYellow
} else {
    Invoke-AzRestJson -Method PUT -Url "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/${resourceGroup}?api-version=2021-04-01" -Body @{ location = $location } | Out-Null
    Write-Host " OK" -ForegroundColor Green
}

Write-Host "Ensuring ADX cluster..." -NoNewline
$clusterExists = $null
try {
    $clusterExists = Invoke-AzRestJson -Method GET -Url "https://management.azure.com${clusterResourceId}?api-version=2023-08-15" -AllowNotFound
} catch {
    if ($_.Exception.Message -notmatch 'NotFound|Not Found|ResourceNotFound') { throw }
}
if ($clusterExists) {
    $clusterState = $clusterExists.properties.provisioningState
    if (-not $clusterState) { $clusterState = $clusterExists.properties.state }
    Write-Host " EXISTS ($clusterState)" -ForegroundColor DarkYellow
} else {
    $clusterBody = @{
        location = $location
        sku = @{
            name = $sku.name
            tier = $sku.tier
            capacity = 1
        }
        properties = @{
            enableStreamingIngest = $true
            enablePurge = $false
            enableAutoStop = $false
            engineType = 'V2'
            publicIPType = 'IPv4'
            publicNetworkAccess = 'Enabled'
            restrictOutboundNetworkAccess = 'Disabled'
            optimizedAutoscale = @{
                isEnabled = $false
                minimum = 1
                maximum = 1
                version = 1
            }
        }
    }
    Invoke-AzRestJson -Method PUT -Url "https://management.azure.com${clusterResourceId}?api-version=2023-08-15" -Body $clusterBody | Out-Null
    Write-Host " OK" -ForegroundColor Green
}

$cluster = Wait-KustoResourceSucceeded -ResourceId $clusterResourceId -ResourceName "ADX cluster $clusterName" -TimeoutMinutes 45
if ($cluster.properties.uri) {
    $adxConfig.queryBaseUri = $cluster.properties.uri
    $adxConfig.ingestBaseUri = $cluster.properties.uri
}
Update-InstallationDefinitions -Definitions $defs -Path $InstallationDefinitionsPath -AdxConfig $adxConfig

Write-Host "Ensuring ADX database..." -NoNewline
$databaseExists = $null
try {
    $databaseExists = Invoke-AzRestJson -Method GET -Url "https://management.azure.com${databaseResourceId}?api-version=2023-08-15" -AllowNotFound
} catch {
    if ($_.Exception.Message -notmatch 'NotFound|Not Found|ResourceNotFound|Cannot fetch databases while resource is in state') { throw }
}
if ($databaseExists) {
    $databaseState = $databaseExists.properties.provisioningState
    if (-not $databaseState) { $databaseState = $databaseExists.properties.state }
    Write-Host " EXISTS ($databaseState)" -ForegroundColor DarkYellow
} else {
    $databaseBody = @{
        kind = 'ReadWrite'
        location = $location
        properties = @{
            softDeletePeriod = 'P365D'
        }
    }
    Invoke-AzRestJson -Method PUT -Url "https://management.azure.com${databaseResourceId}?api-version=2023-08-15" -Body $databaseBody | Out-Null
    Write-Host " OK" -ForegroundColor Green
}

Wait-KustoResourceSucceeded -ResourceId $databaseResourceId -ResourceName "ADX database $databaseName" -TimeoutMinutes 20 | Out-Null

Write-Host "Assigning Database Ingestor..." -NoNewline
$principalBody = @{
    properties = @{
        principalId = $ClientId
        principalType = 'App'
        role = 'Ingestor'
        tenantId = $TenantId
    }
}
$createdIngestorAssignment = Invoke-AzRestJsonIdempotentPut `
    -Url "https://management.azure.com${databaseResourceId}/principalAssignments/${assignmentName}?api-version=2023-08-15" `
    -Body $principalBody `
    -AlreadyExistsPattern 'already exists with the same role and principal id'
if ($createdIngestorAssignment) { Write-Host " OK" -ForegroundColor Green }
else { Write-Host " EXISTS" -ForegroundColor DarkYellow }

if ($currentUserObjectId) {
    Write-Host "Assigning current user as Database Admin..." -NoNewline
    $currentTenantId = & az account show --query tenantId -o tsv
    $currentUserBody = @{
        properties = @{
            principalId = $currentUserObjectId
            principalType = 'User'
            role = 'Admin'
            tenantId = $currentTenantId
        }
    }
    $createdAdminAssignment = Invoke-AzRestJsonIdempotentPut `
        -Url "https://management.azure.com${databaseResourceId}/principalAssignments/${currentUserAdminAssignmentName}?api-version=2023-08-15" `
        -Body $currentUserBody `
        -AlreadyExistsPattern 'already exists with the same role and principal id'
    if ($createdAdminAssignment) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " EXISTS" -ForegroundColor DarkYellow }
} else {
    Write-Host "  [WARN] Could not resolve current user object id; skipping Database Admin self-assignment." -ForegroundColor Yellow
}

Write-Host "Waiting for cluster endpoint to accept management commands..."
for ($i = 1; $i -le 60; $i++) {
    try {
        Invoke-KustoManagementCommand -ClusterUri $clusterUri -Database $databaseName -Command '.show version'
        break
    } catch {
        if ($i -eq 60) { throw }
        Start-Sleep -Seconds 20
    }
}

Write-Host "Creating table and ingestion mapping..." -NoNewline
$escapedTableName = Escape-KustoName -Name $tableName
$escapedMappingName = Escape-KustoName -Name $mappingName
$mappingJson = '[{ "column": "TimeGenerated", "datatype": "datetime", "path": "$.TimeGenerated" },{ "column": "Event", "datatype": "dynamic", "path": "$.Event" }]'
Invoke-KustoManagementCommand -ClusterUri $clusterUri -Database $databaseName -Command ".create-merge table ['$escapedTableName'] (TimeGenerated:datetime, Event:dynamic)"
Invoke-KustoManagementCommand -ClusterUri $clusterUri -Database $databaseName -Command ".alter table ['$escapedTableName'] policy streamingingestion '{""IsEnabled"": true}'"
Invoke-KustoManagementCommand -ClusterUri $clusterUri -Database $databaseName -Command ".create-or-alter table ['$escapedTableName'] ingestion json mapping '$escapedMappingName' '$mappingJson'"
Write-Host " OK" -ForegroundColor Green

if ($ClientSecret) {
    Write-Host "Storing ADX client secret in Key Vault..." -NoNewline
    Set-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $ClientSecretName -SecretValue $ClientSecret
    Write-Host " OK" -ForegroundColor Green
} else {
    $existingSecretId = & az keyvault secret show --vault-name $keyVaultName --name $ClientSecretName --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingSecretId) {
        Write-Host "ADX client secret already exists in Key Vault." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Client secret '$ClientSecretName' was not found in Key Vault '$keyVaultName'." -ForegroundColor Yellow
        Write-Host "         ADX resources were provisioned. Step 5 stores 'agent-client-secret' for app-claudia-dataagent, which ADX can reuse." -ForegroundColor Yellow
    }
}

Update-InstallationDefinitions -Definitions $defs -Path $InstallationDefinitionsPath -AdxConfig $adxConfig
Sync-SourceConfigAdx -DefinitionsPath $InstallationDefinitionsPath -Definitions $defs -AdxConfig $adxConfig

Write-Host ""
Write-Host "ADX telemetry configuration saved to:" -ForegroundColor Green
Write-Host "  $InstallationDefinitionsPath"
