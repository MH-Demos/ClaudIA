<#PSScriptInfo

.VERSION 1.0.0

.GUID 8264a309-d2cf-4f56-ada3-81cdf11768cb

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
Deploys the Azure Playwright Workspace used by BrowserAgents

.RELEASENOTES
Initial version metadata for Deploys the Azure Playwright Workspace used by BrowserAgents.

#>
<#
.SYNOPSIS
    Deploys the Azure Playwright Workspace used by BrowserAgents.
.DESCRIPTION
    Creates or updates a Microsoft.LoadTestService/playwrightWorkspaces resource
    in the lab subscription. The workspace provides cloud-hosted browsers for
    Office Web, OWA, SharePoint Web, and SaaS upload/paste automation.
.EXAMPLE
    .\tools\Deploy-BrowserAgentInfra.ps1
.EXAMPLE
    .\tools\Deploy-BrowserAgentInfra.ps1 -Location eastus -WorkspaceName pw-claudia-lab
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = '',
    [string]$Location = 'eastus',
    [string]$WorkspaceName = 'pw-claudia-lab',
    [switch]$AssignCurrentUserRole
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param([string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output | Out-String)
    }
    if ($output) { return ($output | Out-String | ConvertFrom-Json) }
    return $null
}

function Wait-ProviderRegistered {
    param([string]$Namespace)
    & az provider register --namespace $Namespace --only-show-errors | Out-Null
    $deadline = (Get-Date).AddMinutes(8)
    do {
        Start-Sleep -Seconds 10
        $state = (& az provider show --namespace $Namespace --query registrationState -o tsv)
        Write-Host "  $Namespace`: $state"
    } while ($state -ne 'Registered' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Registered') { throw "$Namespace provider registration timed out." }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $SubscriptionId) { $SubscriptionId = $config.tenant.subscriptionId }
if (-not $ResourceGroup) { $ResourceGroup = $config.infrastructure.resourceGroup }

Write-Host "=== Deploy BrowserAgent Infrastructure ===" -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  Resource RG:  $ResourceGroup"
Write-Host "  Workspace:    $WorkspaceName"
Write-Host "  Location:     $Location"
Write-Host ""

& az account set --subscription $SubscriptionId
Wait-ProviderRegistered -Namespace 'Microsoft.LoadTestService'

$rg = Invoke-AzCliJson -Arguments @('group','show','-n',$ResourceGroup,'-o','json')
Write-Host "  Resource group exists: $($rg.location)" -ForegroundColor Green

$api = '2026-02-01-preview'
$body = @{
    location = $Location
    identity = @{ type = 'SystemAssigned' }
    properties = @{
        localAuth = 'Disabled'
        regionalAffinity = 'Enabled'
        reporting = 'Disabled'
    }
    tags = @{
        workload = 'ClaudIA'
        component = 'BrowserAgents'
        purpose = 'PurviewActivityExplorer'
    }
} | ConvertTo-Json -Depth 8

$tmp = Join-Path $env:TEMP "browser-agent-playwright-workspace-$WorkspaceName-$([guid]::NewGuid().ToString('n')).json"
Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8
$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.LoadTestService/playwrightWorkspaces/$WorkspaceName`?api-version=$api"
$workspace = Invoke-AzCliJson -Arguments @('rest','--method','put','--uri',$uri,'--body',"@$tmp",'-o','json')
Write-Host "  Workspace provisioning: $($workspace.properties.provisioningState)" -ForegroundColor Yellow

$deadline = (Get-Date).AddMinutes(8)
do {
    Start-Sleep -Seconds 10
    $workspace = Invoke-AzCliJson -Arguments @('rest','--method','get','--uri',$uri,'-o','json')
    Write-Host "  Workspace state: $($workspace.properties.provisioningState)"
} while ($workspace.properties.provisioningState -notin @('Succeeded','Failed','Canceled') -and (Get-Date) -lt $deadline)

if ($workspace.properties.provisioningState -ne 'Succeeded') {
    throw "Playwright workspace provisioning ended with state '$($workspace.properties.provisioningState)'."
}

if ($AssignCurrentUserRole) {
    $currentUserObjectId = (& az ad signed-in-user show --query id -o tsv)
    if ($currentUserObjectId) {
        & az role assignment create `
            --assignee $currentUserObjectId `
            --role 'Playwright Workspace Contributor' `
            --scope $workspace.id `
            -o none 2>$null
        Write-Host "  RBAC checked: Playwright Workspace Contributor for current user" -ForegroundColor Green
    }
}

$serviceUrl = "wss://$Location.api.playwright.microsoft.com/playwrightworkspaces/$($workspace.properties.workspaceId)/browsers"

Write-Host ""
Write-Host "BrowserAgent workspace ready:" -ForegroundColor Green
$result = [pscustomobject]@{
    SubscriptionId = $SubscriptionId
    ResourceGroup = $ResourceGroup
    WorkspaceName = $WorkspaceName
    WorkspaceId = $workspace.properties.workspaceId
    DataplaneUri = $workspace.properties.dataplaneUri
    PlaywrightServiceUrl = $serviceUrl
    ProvisioningState = $workspace.properties.provisioningState
}
$result | Format-List

Write-Host "Add PLAYWRIGHT_SERVICE_URL to BrowserAgents/.env when running tests." -ForegroundColor Yellow
$result



