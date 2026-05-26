<#PSScriptInfo

.VERSION 1.0.0

.GUID 1fe93420-48b6-4a89-aaef-5b931b4eaf59

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
Query recent low-complexity file operations generated for Purview Activity Explorer validation

.RELEASENOTES
Initial version metadata for Query recent low-complexity file operations generated for Purview Activity Explorer validation.

#>
<#
.SYNOPSIS
    Query recent low-complexity file operations generated for Purview Activity Explorer validation.
.EXAMPLE
    .\tools\Get-ActivityExplorerFileOps.ps1
.EXAMPLE
    .\tools\Get-ActivityExplorerFileOps.ps1 -Agent ana.rodriguez -SinceHours 6
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [int]$SinceHours = 24,
    [string]$Agent,
    [int]$Top = 100
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
if (-not $config.adx -or $config.adx.enabled -ne $true) { throw 'ADX telemetry is not configured.' }

az account set -s $config.tenant.subscriptionId 2>$null
$token = az account get-access-token --resource 'https://kusto.kusto.windows.net' --query accessToken -o tsv 2>$null
if (-not $token) { throw 'Could not acquire Kusto token. Run az login first.' }

$tableName = [string]$config.adx.tableName
$agentFilter = ''
if ($Agent) {
    $escapedAgent = $Agent.Replace("'", "''")
    $agentFilter = "| where AgentUPN has '$escapedAgent' or AgentName has '$escapedAgent'"
}

$query = @"
table('$tableName')
| where TimeGenerated > ago($SinceHours`h)
| extend
    ActivityType = tostring(Event.ActivityType),
    Action = tostring(Event.Action),
    AgentUPN = tostring(Event.AgentUPN),
    AgentName = tostring(Event.AgentName),
    TargetName = tostring(Event.TargetName),
    TargetPath = tostring(Event.TargetPath),
    TargetType = tostring(Event.TargetType),
    Outcome = tostring(Event.Outcome),
    ActivityExplorerTarget = tobool(Event.ActivityExplorerTarget),
    DownloadedBytes = tolong(Event.DownloadedBytes),
    ErrorMessage = tostring(Event.ErrorMessage)
| where ActivityType == 'activity_explorer' or ActivityExplorerTarget == true
$agentFilter
| project TimeGenerated, AgentName, AgentUPN, Action, Outcome, TargetType, TargetName, TargetPath, DownloadedBytes, ErrorMessage
| order by TimeGenerated desc
| take $Top
"@

$body = @{ db = $config.adx.databaseName; csl = $query } | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Method POST `
    -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $body -ErrorAction Stop

Write-Host "=== Activity Explorer File Operations ===" -ForegroundColor Cyan
Write-Host "  Window: last $SinceHours hour(s)"
if ($Agent) { Write-Host "  Agent:  $Agent" }
Write-Host ""

if (-not $result.Tables -or $result.Tables[0].Rows.Count -eq 0) {
    Write-Host "No file operation telemetry found." -ForegroundColor DarkYellow
    return
}

$result.Tables[0].Rows | ForEach-Object {
    [PSCustomObject]@{
        Time = ([datetime]$_[0]).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Agent = $_[1]
        UPN = $_[2]
        Action = $_[3]
        Outcome = $_[4]
        Type = $_[5]
        Target = $_[6]
        Bytes = $_[8]
        Error = $_[9]
    }
} | Format-Table -AutoSize



