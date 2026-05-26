<#PSScriptInfo

.VERSION 1.0.1

.GUID 996556ca-065e-4cf2-ac21-bddcf1e65bcb

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
Shows recent BrowserAgent Azure Container Apps Job executions

.RELEASENOTES
Version 1.0.1 checks all configured regional BrowserAgent Container Apps Jobs.

#>
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
    [string]$BrowserRegionKey = '',
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

$regionConfigs = @($config.browserAgents.regionalWorkspaces)
if ($regionConfigs.Count -eq 0) { $regionConfigs = @([pscustomobject]@{ key = 'default' }) }
if ($BrowserRegionKey) {
    $regionConfigs = @($regionConfigs | Where-Object {
        ([string]$_.key).Equals($BrowserRegionKey, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($regionConfigs.Count -eq 0) { throw "Browser region '$BrowserRegionKey' was not found in browserAgents.regionalWorkspaces." }
}

$jobPlans = @()
foreach ($regionConfig in $regionConfigs) {
    $key = if ($regionConfig.key) { [string]$regionConfig.key } else { 'default' }
    $prefix = if ($BrowserRegionKey -or $regionConfigs.Count -eq 1) {
        $JobNamePrefix
    } else {
        switch ($key) {
            'europe' { 'browseragents-eu' }
            'asia' { 'browseragents-asia' }
            default { 'browseragents' }
        }
    }
    foreach ($schedule in @($config.schedules)) {
        $jobName = (($prefix + '-' + $schedule.name).ToLowerInvariant() -replace '[^a-z0-9-]', '-')
        if ($jobName.Length -gt 32) { $jobName = $jobName.Substring(0, 32).Trim('-') }
        $jobPlans += [pscustomobject]@{ Region = $key; JobName = $jobName }
    }
}

$rows = @()
foreach ($jobPlan in $jobPlans) {
    try {
        $executions = @(Invoke-AzCliJson -Arguments @(
            'containerapp','job','execution','list',
            '-n',$jobPlan.JobName,
            '-g',$ResourceGroup,
            '--query',"[0:$Top]",
            '-o','json'
        ))
        foreach ($execution in $executions) {
            $rows += [PSCustomObject]@{
                Region = $jobPlan.Region
                Job = $jobPlan.JobName
                Execution = $execution.name
                Status = $execution.properties.status
                StartTime = $execution.properties.startTime
                EndTime = $execution.properties.endTime
                ReplicaStatus = ($execution.properties.template.containers.name -join ',')
            }
        }
    } catch {
        $rows += [PSCustomObject]@{
            Region = $jobPlan.Region
            Job = $jobPlan.JobName
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
    $rows | Sort-Object Region,Job,StartTime -Descending | Format-Table -AutoSize
}



