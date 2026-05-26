<#PSScriptInfo

.VERSION 1.0.1

.GUID bfeaf319-3a4b-46b6-9de6-bec468e4d410

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
Validates the BrowserAgent Playwright Workspace resource

.RELEASENOTES
Version 1.0.1 validates all configured regional BrowserAgent Playwright Workspaces.

#>
<#
.SYNOPSIS
    Validates the BrowserAgent Playwright Workspace resource.
.DESCRIPTION
    Checks Azure resource state, RBAC-relevant metadata, and prints the service
    endpoint required by Playwright. This does not run browser tests; use the
    BrowserAgents project for that once npm dependencies are installed.
.EXAMPLE
    .\tools\Test-BrowserAgentWorkspace.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json')
)

$ErrorActionPreference = 'Stop'

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.browserAgents.enabled) { throw "browserAgents.enabled is false or missing in config." }

$sub = $config.browserAgents.subscriptionId
$rg = $config.browserAgents.resourceGroup
$api = '2026-02-01-preview'

Write-Host "=== BrowserAgent Workspace Validation ===" -ForegroundColor Cyan
Write-Host "  Subscription: $sub"
Write-Host "  Resource RG:  $rg"
Write-Host ""

az account set --subscription $sub
$providerState = az provider show --namespace Microsoft.LoadTestService --query registrationState -o tsv

$workspaceConfigs = @($config.browserAgents.regionalWorkspaces)
if ($workspaceConfigs.Count -eq 0) { $workspaceConfigs = @($config.browserAgents) }

$rows = @()
foreach ($workspaceConfig in $workspaceConfigs) {
    $key = if ($workspaceConfig.key) { [string]$workspaceConfig.key } else { 'default' }
    $name = [string]$workspaceConfig.workspaceName
    $location = [string]$workspaceConfig.location
    $uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.LoadTestService/playwrightWorkspaces/$name`?api-version=$api"
    $workspace = az rest --method get --uri $uri -o json | ConvertFrom-Json
    $expectedServiceUrl = "wss://$location.api.playwright.microsoft.com/playwrightworkspaces/$($workspace.properties.workspaceId)/browsers"

    $rows += [pscustomobject]@{
        Key = $key
        Provider = 'Microsoft.LoadTestService'
        ProviderState = $providerState
        WorkspaceName = $workspace.name
        WorkspaceLocation = $workspace.location
        ProvisioningState = $workspace.properties.provisioningState
        WorkspaceId = $workspace.properties.workspaceId
        PlaywrightServiceUrl = $expectedServiceUrl
        LocalAuth = $workspace.properties.localAuth
        RegionalAffinity = $workspace.properties.regionalAffinity
        Reporting = $workspace.properties.reporting
    }
}

$rows | Format-Table Key,WorkspaceName,WorkspaceLocation,ProvisioningState,LocalAuth,RegionalAffinity,Reporting -AutoSize

$notReady = @($rows | Where-Object { $_.ProvisioningState -ne 'Succeeded' })
if ($notReady.Count -gt 0) {
    throw "One or more BrowserAgent Playwright Workspaces are not ready."
}

Write-Host "[OK] BrowserAgent workspace resources are ready." -ForegroundColor Green
Write-Host "Note: running cloud browsers also requires Playwright Workspace RBAC and npm dependencies in BrowserAgents." -ForegroundColor Yellow



