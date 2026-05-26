<#PSScriptInfo

.VERSION 1.0.0

.GUID 3fb0b6d5-8195-4916-8ede-434a02887a46

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
Query recent BrowserAgent telemetry from Azure Data Explorer

.RELEASENOTES
Initial version metadata for Query recent BrowserAgent telemetry from Azure Data Explorer.

#>
<#
.SYNOPSIS
    Query recent BrowserAgent telemetry from Azure Data Explorer.
.EXAMPLE
    .\tools\Get-BrowserAgentTelemetry.ps1
.EXAMPLE
    .\tools\Get-BrowserAgentTelemetry.ps1 -Agent priya.sharma -SinceMinutes 120
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [int]$SinceMinutes = 60,
    [string]$Agent,
    [int]$Top = 50
)

$ErrorActionPreference = 'Stop'

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.adx -or $config.adx.enabled -ne $true) {
    throw 'ADX telemetry is not configured.'
}

if ($config.tenant.subscriptionId) {
    az account set -s $config.tenant.subscriptionId 2>$null
}

$token = az account get-access-token --resource 'https://kusto.kusto.windows.net' --query accessToken -o tsv 2>$null
if (-not $token) { throw 'Could not acquire Kusto token. Run az login first.' }

$agentFilter = ''
if ($Agent) {
    $escapedAgent = $Agent.Replace("'", "''")
    $agentFilter = "| where AgentUPN has '$escapedAgent' or AgentName has '$escapedAgent'"
}

$query = @"
table('$($config.adx.tableName)')
| where TimeGenerated > ago($SinceMinutes`m)
| extend
    Source = tostring(Event.Source),
    AgentUPN = tostring(Event.AgentUPN),
    AgentName = tostring(Event.AgentName),
    Department = tostring(Event.Department),
    ActivityType = tostring(Event.ActivityType),
    Action = tostring(Event.Action),
    Service = tostring(Event.Service),
    Workload = tostring(Event.Workload),
    Detail = tostring(Event.Detail),
    Recipient = tostring(Event.Recipient),
    Outcome = tostring(Event.Outcome),
    ScenarioId = tostring(Event.ScenarioId)
| where Source == 'BrowserAgent'
$agentFilter
| project TimeGenerated, AgentName, AgentUPN, Department, ActivityType, Action, Service, Workload, Detail, Recipient, Outcome, ScenarioId
| order by TimeGenerated desc
| take $Top
"@

$body = @{ db = $config.adx.databaseName; csl = $query } | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Method POST `
    -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $body -ErrorAction Stop

Write-Host '=== BrowserAgent Telemetry ===' -ForegroundColor Cyan
Write-Host "  Window: last $SinceMinutes minute(s)"
if ($Agent) { Write-Host "  Agent:  $Agent" }
Write-Host ''

if (-not $result.Tables -or $result.Tables[0].Rows.Count -eq 0) {
    Write-Host 'No BrowserAgent telemetry found.' -ForegroundColor DarkYellow
    return
}

$result.Tables[0].Rows | ForEach-Object {
    [PSCustomObject]@{
        Time = ([datetime]$_[0]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Agent = $_[1]
        UPN = $_[2]
        Type = $_[4]
        Action = $_[5]
        Service = $_[6]
        Recipient = $_[9]
        Outcome = $_[10]
        Detail = $_[8]
    }
} | Format-Table -AutoSize



