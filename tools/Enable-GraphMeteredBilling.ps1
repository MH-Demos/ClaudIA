<#PSScriptInfo

.VERSION 1.0.0

.GUID 6628773e-fd19-4e77-96ce-252193eb423f

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
Enables Microsoft Graph metered API billing for the lab app registration

.RELEASENOTES
Initial version metadata for Enables Microsoft Graph metered API billing for the lab app registration.

#>
<#
.SYNOPSIS
    Enables Microsoft Graph metered API billing for the lab app registration.
.DESCRIPTION
    Creates or reuses a Microsoft.GraphServices/accounts resource associated
    with the configured app-claudia-dataagent application registration. This is required
    for metered APIs such as SharePoint/OneDrive assignSensitivityLabel.
.EXAMPLE
    .\tools\Enable-GraphMeteredBilling.ps1 -SubscriptionId ab97362c-5d5f-49a5-bf87-c8480e54e062 -ResourceGroup MH-Agents-PAYG
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus',
    [string]$GraphResourceName = 'graph-metered-app-claudia-dataagent',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$AppId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

# Some lab machines have stale Azure CLI extensions with restrictive ACLs. This
# script uses only core Azure CLI commands plus az rest, so isolate extensions to
# keep local extension state from breaking installation automation.
$script:originalAzureExtensionDir = $env:AZURE_EXTENSION_DIR
$script:localAzureExtensionDir = Join-Path $env:TEMP 'aa-empty-azure-cli-extensions'
New-Item -ItemType Directory -Path $script:localAzureExtensionDir -Force | Out-Null
$env:AZURE_EXTENSION_DIR = $script:localAzureExtensionDir

function Invoke-AzJson {
    param([string[]]$AzArgs)
    $output = & az @AzArgs -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }
    if ($output) {
        $text = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        try { return ($text | ConvertFrom-Json) }
        catch { return $text }
    }
    return $null
}

function Wait-ProviderRegistration {
    param([string]$Namespace, [int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $provider = Invoke-AzJson -AzArgs @('provider','show','--namespace',$Namespace)
        $state = [string]$provider.registrationState
        Write-Host "  Provider ${Namespace}: $state" -ForegroundColor Gray
        if ($state -eq 'Registered') { return }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw "Provider '$Namespace' did not reach Registered state within $TimeoutSeconds seconds."
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

if ([string]::IsNullOrWhiteSpace($AppId)) {
    if ($config.adx -and $config.adx.clientId) { $AppId = [string]$config.adx.clientId }
    elseif ($config.application -and $config.application.clientId) { $AppId = [string]$config.application.clientId }
}
if ([string]::IsNullOrWhiteSpace($AppId)) {
    throw 'Could not resolve app-claudia-dataagent AppId from config. Pass -AppId explicitly.'
}

Write-Host "=== Enable Graph Metered Billing ===" -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  Resource RG:  $ResourceGroup"
Write-Host "  RG Location:  $Location"
Write-Host "  Graph name:   $GraphResourceName"
Write-Host "  AppId:        $AppId"
Write-Host ""

$visibleSubscriptions = @((Invoke-AzJson -AzArgs @('account','list','--query','[].id')) | ForEach-Object { [string]$_ })
if ($visibleSubscriptions -notcontains $SubscriptionId) {
    $visible = ($visibleSubscriptions -join ', ')
    throw "Subscription '$SubscriptionId' is not visible to the current Azure CLI account. Visible subscriptions: $visible"
}

Invoke-AzJson -AzArgs @('account','set','--subscription',$SubscriptionId) | Out-Null

Write-Host "Ensuring resource group..." -NoNewline
$rg = $null
try {
    $rg = Invoke-AzJson -AzArgs @('group','show','--name',$ResourceGroup)
} catch {
    $rg = Invoke-AzJson -AzArgs @('group','create','--name',$ResourceGroup,'--location',$Location)
}
Write-Host " [OK] $($rg.location)" -ForegroundColor Green

Write-Host "Registering provider Microsoft.GraphServices..." -ForegroundColor Cyan
& az provider register --namespace Microsoft.GraphServices --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to register provider Microsoft.GraphServices."
}
Wait-ProviderRegistration -Namespace 'Microsoft.GraphServices'

$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.GraphServices/accounts/$GraphResourceName"
$apiVersion = '2023-04-13'
$uri = "https://management.azure.com$resourceId`?api-version=$apiVersion"
$body = @{
    location = 'global'
    properties = @{
        appId = $AppId
    }
} | ConvertTo-Json -Depth 5 -Compress

Write-Host "Creating/updating Microsoft.GraphServices/accounts resource..." -NoNewline
$bodyPath = Join-Path $env:TEMP "graph-metered-billing-$([guid]::NewGuid().ToString('N')).json"
try {
    [System.IO.File]::WriteAllText($bodyPath, $body, [System.Text.Encoding]::UTF8)
    $resource = & az rest --method put --uri $uri --body "@$bodyPath" --headers 'Content-Type=application/json' -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($resource | Out-String).Trim())
    }
    $created = $resource | Out-String | ConvertFrom-Json
}
finally {
    Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
}
Write-Host " [OK] $($created.properties.provisioningState)" -ForegroundColor Green

Write-Host "Validating resource..." -NoNewline
$validation = Invoke-AzJson -AzArgs @(
    'resource','show',
    '--ids',$resourceId,
    '--api-version',$apiVersion
)
$linkedAppId = [string]$validation.properties.appId
if ($linkedAppId -ne $AppId) {
    throw "Graph metered billing resource exists, but linked appId is '$linkedAppId' instead of '$AppId'."
}
Write-Host " [OK]" -ForegroundColor Green

Write-Host ""
Write-Host "Graph metered API billing is enabled for app $AppId." -ForegroundColor Green
Write-Host "A fresh OAuth token is required before retrying assignSensitivityLabel." -ForegroundColor Yellow

[PSCustomObject]@{
    SubscriptionId = $SubscriptionId
    ResourceGroup = $ResourceGroup
    ResourceName = $GraphResourceName
    ResourceId = $resourceId
    AppId = $AppId
    ProvisioningState = $validation.properties.provisioningState
}

if ($null -ne $script:originalAzureExtensionDir) {
    $env:AZURE_EXTENSION_DIR = $script:originalAzureExtensionDir
} else {
    Remove-Item Env:\AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
}



