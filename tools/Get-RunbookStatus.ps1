<#
.SYNOPSIS
    Show recent Azure Automation runbook executions for the autonomous agents lab.
.DESCRIPTION
    Reads the effective installation configuration, resolves the Automation Account,
    lists recent Invoke-AgentRunbook jobs, and prints a compact status table.

    Use -IncludeStreams to fetch warning/error stream counts and recent diagnostic
    snippets for each job. The script does not start jobs and has no Log Analytics
    dependency.
.EXAMPLE
    .\tools\Get-RunbookStatus.ps1
.EXAMPLE
    .\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams
.EXAMPLE
    .\tools\Get-RunbookStatus.ps1 -Agent laura.gomez -IncludeStreams
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [int]$Last = 15,
    [int]$SinceHours = 48,
    [string]$Agent,
    [switch]$IncludeStreams,
    [switch]$IncludeOutput,
    [switch]$ShowSchedules
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function Get-AzHeaders {
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Could not acquire Azure management token. Run az login first." }
    @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
}

function Invoke-AzGet {
    param([Parameter(Mandatory)][string]$Uri)
    Invoke-RestMethod -Method GET -Uri $Uri -Headers (Get-AzHeaders)
}

function Get-AutomationJobStreams {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$JobId
    )

    try {
        @((Invoke-AzGet -Uri "$BaseUri/jobs/${JobId}/streams?api-version=2023-11-01").value)
    } catch {
        @()
    }
}

function Get-AutomationJob {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$JobId
    )

    Invoke-AzGet -Uri "$BaseUri/jobs/${JobId}?api-version=2023-11-01"
}

function Get-AutomationJobOutput {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$JobId
    )

    try {
        [string](Invoke-AzGet -Uri "$BaseUri/jobs/${JobId}/output?api-version=2023-11-01")
    } catch {
        ''
    }
}

function Get-JobParameterValue {
    param($Job, [string]$Name)

    $params = $Job.properties.parameters
    if (-not $params) { return '' }
    if ($params -is [System.Collections.IDictionary] -and $params.Contains($Name)) { return [string]$params[$Name] }
    if ($params.PSObject.Properties[$Name]) { return [string]$params.$Name }
    return ''
}

function Get-ShortStatus {
    param([string]$Status)
    switch ($Status) {
        'Completed' { 'success' }
        'Succeeded' { 'success' }
        'Failed' { 'failed' }
        'Stopped' { 'failed' }
        'Suspended' { 'failed' }
        'Running' { 'running' }
        'New' { 'pending' }
        'Activating' { 'pending' }
        default { if ($Status) { $Status.ToLowerInvariant() } else { 'unknown' } }
    }
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
$subId = [string]$config.tenant.subscriptionId
$aaName = [string]$config.infrastructure.automationAccountName
$configuredRg = [string]$config.infrastructure.resourceGroup

if (-not $subId) { throw 'tenant.subscriptionId is missing from the effective configuration.' }
if (-not $aaName) { throw 'infrastructure.automationAccountName is missing from the effective configuration.' }

az account set -s $subId 2>$null

$aaId = az resource list --resource-type Microsoft.Automation/automationAccounts --query "[?name=='$aaName'].id | [0]" -o tsv 2>$null
if (-not $aaId) { throw "Automation Account '$aaName' was not found in subscription '$subId'." }

$rg = $configuredRg
if ($aaId -match '/resourceGroups/([^/]+)/') { $rg = $Matches[1] }
$baseUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName"

Write-Host "=== Runbook Status ===" -ForegroundColor Cyan
Write-Host "  Automation: $aaName ($rg)"
Write-Host "  Runbook:    Invoke-AgentRunbook"
Write-Host "  Window:     last $SinceHours hour(s)"
Write-Host ""

if ($ShowSchedules) {
    try {
        $schedules = @((Invoke-AzGet -Uri "$baseUri/schedules?api-version=2023-11-01").value | Sort-Object { $_.properties.startTime })
        if ($schedules.Count -gt 0) {
            Write-Host "=== Schedules ===" -ForegroundColor Cyan
            $schedules | ForEach-Object {
                [PSCustomObject]@{
                    Name = $_.name
                    Enabled = $_.properties.isEnabled
                    Frequency = $_.properties.frequency
                    Interval = $_.properties.interval
                    TimeZone = $_.properties.timeZone
                    StartTime = $_.properties.startTime
                }
            } | Format-Table -AutoSize
            Write-Host ""
        }
    } catch {
        Write-Host "[WARN] Could not read schedules: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
    }
}

$jobs = @()
$nextUri = "$baseUri/jobs?api-version=2023-11-01"
do {
    $page = Invoke-AzGet -Uri $nextUri
    $jobs += @($page.value)
    $nextUri = $page.nextLink
} while ($nextUri -and $jobs.Count -lt [Math]::Max($Last * 3, 50))

$since = (Get-Date).ToUniversalTime().AddHours(-1 * [Math]::Abs($SinceHours))
$jobs = @($jobs | Where-Object {
    $_.properties.runbook.name -eq 'Invoke-AgentRunbook' -and
    ([datetime]$_.properties.creationTime).ToUniversalTime() -ge $since
} | Sort-Object { [datetime]$_.properties.creationTime } -Descending)

if ($Agent) {
    $agentLower = $Agent.ToLowerInvariant()
    $jobs = @($jobs | Where-Object {
        (Get-JobParameterValue -Job $_ -Name 'RunAsAgent').ToLowerInvariant() -eq $agentLower
    })
}

$jobs = @($jobs | Select-Object -First $Last)
if ($jobs.Count -eq 0) {
    Write-Host "No recent Invoke-AgentRunbook jobs found for the selected filters." -ForegroundColor DarkYellow
    return
}

$rows = @()
foreach ($job in $jobs) {
    $jobId = [string]$job.name
    try {
        $job = Get-AutomationJob -BaseUri $baseUri -JobId $jobId
    } catch {
        # Keep the list payload when job detail is temporarily unavailable.
    }
    $props = $job.properties
    $runAsAgent = Get-JobParameterValue -Job $job -Name 'RunAsAgent'
    $activityMode = Get-JobParameterValue -Job $job -Name 'ActivityMode'
    $skipWeekend = Get-JobParameterValue -Job $job -Name 'SkipWeekendCheck'
    $startTime = if ($props.startTime) { [datetime]$props.startTime } else { $null }
    $endTime = if ($props.endTime) { [datetime]$props.endTime } else { $null }
    $duration = ''
    if ($startTime -and $endTime) {
        $duration = '{0:hh\:mm\:ss}' -f ($endTime - $startTime)
    } elseif ($startTime) {
        $duration = '{0:hh\:mm\:ss}' -f ((Get-Date).ToUniversalTime() - $startTime.ToUniversalTime())
    }

    $warnings = 0
    $errors = 0
    $diagnostic = ''
    if ($IncludeStreams) {
        $streams = Get-AutomationJobStreams -BaseUri $baseUri -JobId $jobId
        $warningStreams = @($streams | Where-Object { $_.properties.streamType -eq 'Warning' })
        $errorStreams = @($streams | Where-Object { $_.properties.streamType -eq 'Error' })
        $warnings = $warningStreams.Count
        $errors = $errorStreams.Count
        $firstIssue = @($errorStreams + $warningStreams | Select-Object -First 1)
        if ($firstIssue.Count -gt 0) {
            $diagnostic = (($firstIssue[0].properties.summary -replace '\s+', ' ').Trim())
            if ($diagnostic.Length -gt 140) { $diagnostic = $diagnostic.Substring(0, 140) + '...' }
        }
    }

    $files = $null
    $emails = $null
    $threadEmails = $null
    $outputSummary = ''
    if ($IncludeOutput -or $IncludeStreams) {
        $output = Get-AutomationJobOutput -BaseUri $baseUri -JobId $jobId
        if ($output -match '=== COMPLETE:\s*(\d+)\s*files uploaded,\s*(\d+)\s*emails \+\s*(\d+)\s*thread emails sent') {
            $files = [int]$Matches[1]
            $emails = [int]$Matches[2]
            $threadEmails = [int]$Matches[3]
            $outputSummary = "$files files, $emails email(s), $threadEmails thread email(s)"
        } elseif ($IncludeOutput -and $output) {
            $interesting = @($output -split "`n" | Where-Object { $_ -match 'AUTH|ADX|DONE|COMPLETE|failed|Failed' } | Select-Object -Last 2)
            $outputSummary = (($interesting -join ' | ') -replace '\s+', ' ').Trim()
            if ($outputSummary.Length -gt 160) { $outputSummary = $outputSummary.Substring(0, 160) + '...' }
        }
    }

    $status = Get-ShortStatus -Status ([string]$props.status)
    if ($status -eq 'success' -and ($errors -gt 0 -or $warnings -gt 0)) { $status = 'partial' }
    $jobKind = if ($runAsAgent) { 'agent' } elseif ($activityMode -eq 'full') { 'scheduled-full' } elseif ($activityMode) { $activityMode } else { 'unknown' }

    $rows += [PSCustomObject][ordered]@{
        Created = ([datetime]$props.creationTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        Agent = if ($runAsAgent) { $runAsAgent } else { '-' }
        Mode = if ($activityMode) { $activityMode } else { '-' }
        Kind = $jobKind
        AzureStatus = $props.status
        Status = $status
        Duration = $duration
        Warnings = $warnings
        Errors = $errors
        Output = $outputSummary
        Diagnostic = $diagnostic
        JobId = $jobId
    }
}

$rows | Format-Table -AutoSize

$summary = $rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ""
Write-Host "Summary: $($summary -join ', ')" -ForegroundColor Cyan
