<#
.SYNOPSIS
    Shows recent BrowserAgent Azure Container Apps Job executions.
.EXAMPLE
    .\tools\Get-BrowserAgentScheduledJobStatus.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = '',
    [string]$JobNamePrefix = 'browseragents',
    [int]$Top = 10
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param([string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output | Out-String) }
    $text = ($output | Out-String).Trim()
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $SubscriptionId) { $SubscriptionId = $config.browserAgents.subscriptionId ?? $config.tenant.subscriptionId }
if (-not $ResourceGroup) { $ResourceGroup = $config.browserAgents.resourceGroup ?? $config.infrastructure.resourceGroup }

& az account set --subscription $SubscriptionId

$rows = @()
foreach ($schedule in @($config.schedules)) {
    $jobName = (($JobNamePrefix + '-' + $schedule.name).ToLowerInvariant() -replace '[^a-z0-9-]', '-')
    if ($jobName.Length -gt 32) { $jobName = $jobName.Substring(0, 32).Trim('-') }

    try {
        $executions = @(Invoke-AzCliJson -Arguments @(
            'containerapp','job','execution','list',
            '-n',$jobName,
            '-g',$ResourceGroup,
            '--query',"[0:$Top]",
            '-o','json'
        ))
        foreach ($execution in $executions) {
            $rows += [PSCustomObject]@{
                Job = $jobName
                Execution = $execution.name
                Status = $execution.properties.status
                StartTime = $execution.properties.startTime
                EndTime = $execution.properties.endTime
                ReplicaStatus = ($execution.properties.template.containers.name -join ',')
            }
        }
    } catch {
        $rows += [PSCustomObject]@{
            Job = $jobName
            Execution = ''
            Status = 'not-found-or-unavailable'
            StartTime = ''
            EndTime = ''
            ReplicaStatus = $_.Exception.Message
        }
    }
}

Write-Host '=== BrowserAgent Scheduled Job Status ===' -ForegroundColor Cyan
if ($rows.Count -eq 0) {
    Write-Host 'No executions found.' -ForegroundColor Yellow
} else {
    $rows | Sort-Object StartTime -Descending | Format-Table -AutoSize
}
