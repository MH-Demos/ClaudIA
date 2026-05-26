<#PSScriptInfo

.VERSION 1.0.0

.GUID 941e9fb0-c246-4e6e-aee1-c3919b24e95c

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
Query recent sensitivity label activity from ADX telemetry

.RELEASENOTES
Initial version metadata for Query recent sensitivity label activity from ADX telemetry.

#>
<#
.SYNOPSIS
    Query recent sensitivity label activity from ADX telemetry.
.EXAMPLE
    .\tools\Get-LabelActivity.ps1
.EXAMPLE
    .\tools\Get-LabelActivity.ps1 -Agent laura.gomez -SinceHours 24
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
    Label = tostring(Event.SensitivityLabel),
    PreviousLabel = tostring(Event.PreviousSensitivityLabel),
    TargetName = tostring(Event.TargetName),
    TargetPath = tostring(Event.TargetPath),
    Outcome = tostring(Event.Outcome),
    ErrorMessage = tostring(Event.ErrorMessage)
| where ActivityType == 'sensitivity_label' or Action startswith 'SensitivityLabel'
$agentFilter
| project TimeGenerated, AgentName, AgentUPN, Action, Outcome, Label, PreviousLabel, TargetName, TargetPath, ErrorMessage
| order by TimeGenerated desc
| take $Top
"@

$body = @{ db = $config.adx.databaseName; csl = $query } | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Method POST `
    -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $body -ErrorAction Stop

Write-Host "=== Sensitivity Label Activity ===" -ForegroundColor Cyan
Write-Host "  Window: last $SinceHours hour(s)"
if ($Agent) { Write-Host "  Agent:  $Agent" }
Write-Host ""

if (-not $result.Tables -or $result.Tables[0].Rows.Count -eq 0) {
    Write-Host "No sensitivity label telemetry found." -ForegroundColor DarkYellow
    return
}

$result.Tables[0].Rows | ForEach-Object {
    [PSCustomObject]@{
        Time = ([datetime]$_[0]).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Agent = $_[1]
        UPN = $_[2]
        Action = $_[3]
        Outcome = $_[4]
        Label = $_[5]
        Previous = $_[6]
        Target = $_[7]
        Error = $_[9]
    }
} | Format-Table -AutoSize



