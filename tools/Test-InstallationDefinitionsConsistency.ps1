<#
.SYNOPSIS
    Validate that installation-specific values are consistent across config files.
.DESCRIPTION
    Checks that config/Installation_definitions.json is present, builds the
    effective configuration, and reports common stale-value issues such as old
    ADX tenants, ingest-prefixed ADX URIs, or mismatched ADX blocks.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath -RequireInstallationDefinitions
$config = $effective.Config
$defs = $effective.Definitions
$issues = @()

function Add-Issue {
    param([string]$Message)
    $script:issues += $Message
}

if (-not $defs.tenant.tenantId) { Add-Issue "tenant.tenantId is missing from Installation_definitions.json." }
if (-not $defs.infrastructure.keyVaultName) { Add-Issue "infrastructure.keyVaultName is missing from Installation_definitions.json." }
if (-not $defs.infrastructure.openAiAccountName) { Add-Issue "infrastructure.openAiAccountName is missing from Installation_definitions.json." }
if (-not $defs.agents -or @($defs.agents).Count -eq 0) { Add-Issue "agents is empty or missing from Installation_definitions.json." }

if ($config.adx -and $config.adx.enabled -eq $true) {
    foreach ($prop in @('tenantId','clientId','clientSecretName','keyVaultName','clusterName','databaseName','tableName','mappingName','queryBaseUri','ingestBaseUri')) {
        if (-not $config.adx.PSObject.Properties[$prop] -or [string]::IsNullOrWhiteSpace([string]$config.adx.$prop)) {
            Add-Issue "adx.$prop is missing or empty."
        }
    }
    if ([string]$config.adx.ingestBaseUri -match '://ingest-') {
        Add-Issue "adx.ingestBaseUri uses an ingest-prefixed host. Streaming REST ingestion should use the cluster URI."
    }
    if ($config.adx.queryBaseUri -and $config.adx.ingestBaseUri -and $config.adx.queryBaseUri.TrimEnd('/') -ne $config.adx.ingestBaseUri.TrimEnd('/')) {
        Add-Issue "adx.queryBaseUri and adx.ingestBaseUri differ. For this solution both should use the cluster URI."
    }
    if ($defs.steps -and $defs.steps.PSObject.Properties['4'] -and $defs.steps.'4'.adx) {
        if ($defs.steps.'4'.adx.tenantId -ne $defs.adx.tenantId) { Add-Issue "steps.4.adx.tenantId does not match adx.tenantId." }
        if ($defs.steps.'4'.adx.ingestBaseUri -ne $defs.adx.ingestBaseUri) { Add-Issue "steps.4.adx.ingestBaseUri does not match adx.ingestBaseUri." }
        if ($defs.steps.'4'.adx.clientId -ne $defs.adx.clientId) { Add-Issue "steps.4.adx.clientId does not match adx.clientId." }
    }
}

Write-Host "=== Installation Definitions Consistency ===" -ForegroundColor Cyan
Write-Host "  Tenant:       $($config.tenant.domain) / $($config.tenant.tenantId)"
Write-Host "  Subscription: $($config.tenant.subscriptionId)"
Write-Host "  Resource RG:  $($config.infrastructure.resourceGroup)"
Write-Host "  Key Vault:    $($config.infrastructure.keyVaultName)"
Write-Host "  OpenAI:       $($config.infrastructure.openAiAccountName)"
Write-Host "  Agents:       $(@($config.agents).Count)"
if ($config.adx) {
    Write-Host "  ADX:          $($config.adx.clusterName) / $($config.adx.databaseName) / $($config.adx.tableName)"
    Write-Host "  ADX URI:      $($config.adx.ingestBaseUri)"
}

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "[FAIL] Found $($issues.Count) consistency issue(s):" -ForegroundColor Red
    foreach ($issue in $issues) { Write-Host "  - $issue" -ForegroundColor Yellow }
    exit 1
}

Write-Host ""
Write-Host "[OK] Installation definitions are consistent." -ForegroundColor Green
