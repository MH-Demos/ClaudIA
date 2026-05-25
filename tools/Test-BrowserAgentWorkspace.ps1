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
$name = $config.browserAgents.workspaceName
$location = $config.browserAgents.location
$api = '2026-02-01-preview'

Write-Host "=== BrowserAgent Workspace Validation ===" -ForegroundColor Cyan
Write-Host "  Subscription: $sub"
Write-Host "  Resource RG:  $rg"
Write-Host "  Workspace:    $name"
Write-Host ""

az account set --subscription $sub
$providerState = az provider show --namespace Microsoft.LoadTestService --query registrationState -o tsv
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.LoadTestService/playwrightWorkspaces/$name`?api-version=$api"
$workspace = az rest --method get --uri $uri -o json | ConvertFrom-Json

$expectedServiceUrl = "wss://$location.api.playwright.microsoft.com/playwrightworkspaces/$($workspace.properties.workspaceId)/browsers"

[pscustomobject]@{
    Provider = 'Microsoft.LoadTestService'
    ProviderState = $providerState
    WorkspaceName = $workspace.name
    WorkspaceLocation = $workspace.location
    ProvisioningState = $workspace.properties.provisioningState
    WorkspaceId = $workspace.properties.workspaceId
    DataplaneUri = $workspace.properties.dataplaneUri
    PlaywrightServiceUrl = $expectedServiceUrl
    LocalAuth = $workspace.properties.localAuth
    RegionalAffinity = $workspace.properties.regionalAffinity
    Reporting = $workspace.properties.reporting
} | Format-List

if ($workspace.properties.provisioningState -ne 'Succeeded') {
    throw "Workspace is not ready."
}

Write-Host "[OK] BrowserAgent workspace resource is ready." -ForegroundColor Green
Write-Host "Note: running cloud browsers also requires Playwright Workspace RBAC and npm dependencies in BrowserAgents." -ForegroundColor Yellow
