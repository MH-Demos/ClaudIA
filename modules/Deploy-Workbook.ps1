<#PSScriptInfo

.VERSION 1.0.0

.GUID 1512651d-a076-4bf9-9db4-77abf247b494

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
Deploy the ClaudIA Activity Monitor workbook backed by Azure Data Explorer

.RELEASENOTES
Initial version metadata for Deploy the ClaudIA Activity Monitor workbook backed by Azure Data Explorer.

#>
<#
.SYNOPSIS
    Deploy the ClaudIA Activity Monitor workbook backed by Azure Data Explorer.
.DESCRIPTION
    Creates an Azure Monitor Workbook with KQL query sections that visualize
    agent telemetry from the ADX table configured in config/Installation_definitions.json.

    The workbook queries the ADX table directly with the schema:
      TimeGenerated: datetime
      Event: dynamic
.PARAMETER Config
    Parsed agents.json configuration object.
#>
param($Config, [switch]$WhatIf)

if (-not $Config.adx -or $Config.adx.enabled -ne $true) {
    Write-Host "  [SKIP] ADX telemetry is not enabled; Step 7 requires ADX." -ForegroundColor DarkYellow
    return
}

$rg = $Config.infrastructure.resourceGroup
$sub = $Config.tenant.subscriptionId
$loc = $Config.tenant.location
$adx = $Config.adx

$clusterName = [string]$adx.clusterName
$databaseName = [string]$adx.databaseName
$tableName = [string]$adx.tableName
if (-not $clusterName -or -not $databaseName -or -not $tableName) {
    throw "ADX workbook requires adx.clusterName, adx.databaseName, and adx.tableName. Re-run Step 4 first."
}

$clusterResourceGroup = if ($adx.resourceGroup) { [string]$adx.resourceGroup } else { $rg }
$clusterLocation = if ($adx.location) { [string]$adx.location } else { $loc }
$clusterResourceId = "/subscriptions/$sub/resourceGroups/$clusterResourceGroup/providers/Microsoft.Kusto/clusters/$clusterName"
$clusterExists = az resource show --ids $clusterResourceId --query id -o tsv 2>$null
if (-not $clusterExists) {
    throw "ADX cluster '$clusterName' was not found at '$clusterResourceId'. Re-run Step 4 first."
}

$t = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $t) { throw "Could not acquire Azure management token. Run az login first." }
$h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}

function Escape-KustoIdentifier {
    param([Parameter(Mandatory)][string]$Name)
    return $Name.Replace("'", "''")
}

$escapedTable = Escape-KustoIdentifier -Name $tableName
$baseKql = @"
let AgentActivity =
['$escapedTable']
| where TimeGenerated > ago(7d)
| extend
    AgentUPN = tostring(Event.AgentUPN),
    AgentName = tostring(Event.AgentName),
    Department = tostring(Event.Department),
    ActivityType = coalesce(tostring(Event.ActivityType), tostring(Event.Actividad), tostring(Event.Activity)),
    Detail = tostring(Event.Detail),
    PromptTokens = coalesce(tolong(Event.PromptTokens), 0),
    ResponseTokens = coalesce(tolong(Event.ResponseTokens), 0),
    PromptContent = tostring(Event.PromptContent),
    ResponseContent = tostring(Event.ResponseContent)
| where AgentName != 'Test';
"@

function New-AdxWorkbookQueryItem {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Query,
        [string]$Visualization = 'table',
        [int]$Size = 0
    )

    # The Azure Workbooks "Azure Data Explorer" data source (queryType 9) wraps the
    # KQL in an AzureDataExplorerQuery/1.0 envelope that carries the cluster + database.
    # The older "Logs (Analytics)" path (queryType 0 + resourceType/crossComponentResources)
    # does NOT expose a database selector and renders against the cluster's default
    # database (which does not exist on single-database clusters), so every tile fails
    # with "Failed to resolve table". queryType 9 is the correct ADX data source.
    $adxQuery = [ordered]@{
        version      = 'AzureDataExplorerQuery/1.0'
        queryText    = "$baseKql`n$Query"
        clusterName  = "$clusterName.$clusterLocation"
        databaseName = $databaseName
    } | ConvertTo-Json -Compress -Depth 5

    [ordered]@{
        type = 3
        content = [ordered]@{
            version = 'KqlItem/1.0'
            query = $adxQuery
            size = $Size
            title = $Title
            queryType = 9
            visualization = $Visualization
        }
        name = $Name
    }
}

$items = @(
    [ordered]@{
        type = 1
        content = [ordered]@{
            json = "# ClaudIA Activity Monitor`nSource: **Azure Data Explorer** cluster ``$clusterName``, database ``$databaseName``, table ``$tableName``. Each row stores ``TimeGenerated`` plus dynamic ``Event`` telemetry."
        }
        name = 'header'
    }
    (New-AdxWorkbookQueryItem -Name 'overview' -Title 'Activity Overview' -Visualization 'tiles' -Size 4 -Query @"
AgentActivity
| summarize
    Activities = count(),
    Agents = dcount(AgentName),
    Departments = dcount(Department),
    PromptTokens = sum(PromptTokens),
    ResponseTokens = sum(ResponseTokens)
"@)
    (New-AdxWorkbookQueryItem -Name 'timeline' -Title 'Activity Timeline' -Visualization 'timechart' -Query @"
AgentActivity
| summarize Activities = count() by bin(TimeGenerated, 1h), ActivityType
| order by TimeGenerated asc
"@)
    (New-AdxWorkbookQueryItem -Name 'per-agent' -Title 'Activities per Agent' -Visualization 'barchart' -Query @"
AgentActivity
| summarize Activities = count() by AgentName, Department
| order by Activities desc
"@)
    (New-AdxWorkbookQueryItem -Name 'by-type' -Title 'By Activity Type' -Visualization 'piechart' -Size 4 -Query @"
AgentActivity
| summarize Activities = count() by ActivityType
| order by Activities desc
"@)
    (New-AdxWorkbookQueryItem -Name 'tokens' -Title 'Token Consumption by Agent' -Visualization 'barchart' -Query @"
AgentActivity
| summarize PromptTokens = sum(PromptTokens), ResponseTokens = sum(ResponseTokens) by AgentName
| order by PromptTokens + ResponseTokens desc
"@)
    (New-AdxWorkbookQueryItem -Name 'summary' -Title 'Recent Activity Summary' -Visualization 'table' -Query @"
AgentActivity
| project TimeGenerated, AgentName, AgentUPN, Department, ActivityType, Detail, PromptTokens, ResponseTokens
| order by TimeGenerated desc
| take 200
"@)
    [ordered]@{
        type = 1
        content = [ordered]@{
            json = "## AI Prompts and Responses`nRecent prompts and model responses captured in the ADX dynamic Event payload."
        }
        name = 'prompt-header'
    }
    (New-AdxWorkbookQueryItem -Name 'prompts' -Title 'Prompts and Responses' -Visualization 'table' -Query @"
AgentActivity
| where isnotempty(PromptContent) or isnotempty(ResponseContent)
| project TimeGenerated, AgentName, ActivityType, PromptContent, ResponseContent
| order by TimeGenerated desc
| take 100
"@)
    (New-AdxWorkbookQueryItem -Name 'cost' -Title 'Estimated Token Cost by Agent' -Visualization 'table' -Query @"
AgentActivity
| summarize
    Activities = count(),
    PromptTokens = sum(PromptTokens),
    ResponseTokens = sum(ResponseTokens)
    by AgentName
| extend EstCost = round(PromptTokens * 0.00000015 + ResponseTokens * 0.0000006, 4)
| order by EstCost desc
"@)
)

$wbContent = [ordered]@{
    version = 'Notebook/1.0'
    items = $items
    fallbackResourceIds = @($clusterResourceId)
} | ConvertTo-Json -Depth 40

# Use deterministic GUID based on RG + workbook name (idempotent across re-runs).
$wbSeed = "$rg-Agent-Activity-Monitor-ADX"
$wbId = [guid]::new([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($wbSeed))).ToString()
# Filter in PowerShell: a JMESPath --query with quoted keys ("hidden-title") breaks
# across the PowerShell/az quoting layers ('invalid jmespath_type value' error).
$existingWorkbooks = az resource list -g $rg --resource-type "Microsoft.Insights/workbooks" -o json 2>$null | ConvertFrom-Json
$existingWorkbookId = ($existingWorkbooks | Where-Object { $_.tags.'hidden-title' -eq 'ClaudIA Activity Monitor' } | Select-Object -First 1).name
if ($existingWorkbookId) { $wbId = $existingWorkbookId }

$body = [ordered]@{
    location = $loc
    tags = [ordered]@{
        'hidden-title' = 'ClaudIA Activity Monitor'
        'telemetry-source' = 'ADX'
    }
    kind = 'shared'
    properties = [ordered]@{
        displayName = 'ClaudIA Activity Monitor'
        serializedData = $wbContent
        version = '2.0'
        sourceId = $clusterResourceId
        category = 'workbook'
    }
} | ConvertTo-Json -Depth 8

Write-Host "  Deploying ADX workbook..." -NoNewline
if ($WhatIf) {
    Write-Host " [WHATIF]" -ForegroundColor Yellow
    Write-Host "  Would deploy workbook '$wbId' in resource group '$rg'." -ForegroundColor Gray
    Write-Host "  Source: ADX $clusterName/$databaseName/$tableName" -ForegroundColor Gray
    return
}

try {
    $result = Invoke-RestMethod -Method PUT `
        -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/workbooks/${wbId}?api-version=2022-04-01" `
        -Headers $h -Body $body
    Write-Host " [OK] $($result.properties.displayName)" -ForegroundColor Green
    Write-Host "  Source: ADX $clusterName/$databaseName/$tableName" -ForegroundColor Gray
    Write-Host "  Portal: https://portal.azure.com/#resource$($result.id)/workbook" -ForegroundColor Gray
} catch {
    if ($_.Exception.Message -match '409|Conflict') {
        Write-Host " [SKIP] workbook already exists or is still provisioning" -ForegroundColor DarkYellow
        Write-Host "  Re-run Step 7 in a few minutes to update the existing workbook." -ForegroundColor Gray
    } else {
        Write-Host " [FAIL] $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}



