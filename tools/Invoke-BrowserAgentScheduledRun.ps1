<#PSScriptInfo

.VERSION 1.0.0

.GUID a08a7ba5-08cb-49de-ab48-89f9b1a8f1e4

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
Run BrowserAgent daily activity using the schedules defined in config\agents.json

.RELEASENOTES
Initial version metadata for Run BrowserAgent daily activity using the schedules defined in config\agents.json.

#>
<#
.SYNOPSIS
    Run BrowserAgent daily activity using the schedules defined in config\agents.json.
.DESCRIPTION
    This is the scheduler-friendly entry point for BrowserAgents. By default it
    prints the execution plan only. Use -RunNow to execute immediately, or
    -DueOnly to execute only when the current local time is close to one of the
    configured schedules.
.EXAMPLE
    .\tools\Invoke-BrowserAgentScheduledRun.ps1
.EXAMPLE
    .\tools\Invoke-BrowserAgentScheduledRun.ps1 -RunNow -Agents priya.sharma -Services owa
.EXAMPLE
    .\tools\Invoke-BrowserAgentScheduledRun.ps1 -DueOnly -WindowMinutes 20 -ContinueOnFailure
#>
[CmdletBinding()]
param(
    [string[]]$Agents,
    [string[]]$Services = @('owa','copilot','banking'),
    [string]$ExternalRecipient = '',
    [switch]$RunNow,
    [switch]$DueOnly,
    [int]$WindowMinutes = 20,
    [switch]$SendEmail,
    [switch]$Sensitive,
    [string]$Label = 'General',
    [switch]$Azure,
    [switch]$InitializeMissingSessions,
    [switch]$RefreshAuth,
    [switch]$SkipPreflight,
    [switch]$ContinueOnFailure,
    [int]$AdxWaitSeconds = 30,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json')
)

$ErrorActionPreference = 'Stop'

function Get-TimeZoneId {
    param([string]$ConfiguredTimeZone)
    if ([string]::IsNullOrWhiteSpace($ConfiguredTimeZone)) { return [System.TimeZoneInfo]::Local.Id }
    try {
        [System.TimeZoneInfo]::FindSystemTimeZoneById($ConfiguredTimeZone) | Out-Null
        return $ConfiguredTimeZone
    } catch {
        return [System.TimeZoneInfo]::Local.Id
    }
}

function Get-DueSchedules {
    param($Schedules, [int]$WindowMinutes)
    $due = @()
    foreach ($schedule in @($Schedules)) {
        $tzId = Get-TimeZoneId -ConfiguredTimeZone $schedule.timezone
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId)
        $now = [System.TimeZoneInfo]::ConvertTime((Get-Date), $tz)
        $scheduled = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour ([int]$schedule.hour) -Minute ([int]$schedule.minute) -Second 0
        $delta = [Math]::Abs(($now - $scheduled).TotalMinutes)
        if ($delta -le $WindowMinutes) {
            $due += [PSCustomObject]@{
                Name = [string]$schedule.name
                TimeZone = $tzId
                ScheduledLocal = $scheduled
                NowLocal = $now
                DeltaMinutes = [Math]::Round($delta, 1)
            }
        }
    }
    return $due
}

function Test-BrowserSession {
    param([string]$RepoRoot, [string]$Sam)
    Test-Path -LiteralPath (Join-Path $RepoRoot "BrowserAgents\.auth\$Sam.json")
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.browserAgents -or $config.browserAgents.enabled -ne $true) {
    throw 'browserAgents.enabled is not true in config\agents.json.'
}

$selectedAgents = @($config.agents | Where-Object { $_.sam -and $_.userPrincipalName })
if ($Agents -and $Agents.Count -gt 0) {
    $wanted = @{}
    foreach ($agentName in $Agents) { $wanted[$agentName.ToLowerInvariant()] = $true }
    $selectedAgents = @($selectedAgents | Where-Object {
        $wanted.ContainsKey(([string]$_.sam).ToLowerInvariant()) -or
        ($_.userPrincipalName -and $wanted.ContainsKey(([string]$_.userPrincipalName).ToLowerInvariant())) -or
        ($_.displayName -and $wanted.ContainsKey(([string]$_.displayName).ToLowerInvariant()))
    })
}
if (-not $selectedAgents -or $selectedAgents.Count -eq 0) { throw 'No BrowserAgents selected.' }

$servicesText = (($Services -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) -join ','
if (-not $servicesText) { throw 'No services selected.' }
if (-not $ExternalRecipient -and $config.externalRecipients) {
    $ExternalRecipient = (@($config.externalRecipients | Where-Object { $_ }) -join ',')
}
if (-not $ExternalRecipient) { $ExternalRecipient = 'demo.recipient@example.com' }

$dueSchedules = Get-DueSchedules -Schedules $config.schedules -WindowMinutes $WindowMinutes
$shouldRun = $RunNow -or (-not $DueOnly -and $false)
if ($DueOnly) { $shouldRun = $dueSchedules.Count -gt 0 }

Write-Host '=== BrowserAgent Scheduled Run ===' -ForegroundColor Cyan
Write-Host "  Agents:     $($selectedAgents.Count)"
Write-Host "  Services:   $servicesText"
Write-Host "  External:   $ExternalRecipient"
Write-Host "  Mode:       $(if ($Azure) { 'Azure Playwright Workspace' } else { 'local browser' })"
$scheduleText = @($config.schedules | ForEach-Object {
    '{0}={1}:{2:D2} {3}' -f $_.name, [int]$_.hour, [int]$_.minute, $_.timezone
}) -join '; '
Write-Host "  Schedules:  $scheduleText"
Write-Host "  Due now:    $(if ($dueSchedules.Count -gt 0) { ($dueSchedules.Name -join ', ') } else { 'none' })"
Write-Host "  Action:     $(if ($RunNow) { 'run now' } elseif ($DueOnly) { 'run if due' } else { 'plan only' })"
Write-Host ''

$plan = foreach ($agent in $selectedAgents) {
    [PSCustomObject]@{
        Agent = $agent.sam
        DisplayName = $agent.displayName
        UPN = $agent.userPrincipalName
        CopilotLicense = [bool]$agent.copilotLicense
        Session = if (Test-BrowserSession -RepoRoot $repoRoot -Sam $agent.sam) { 'present' } else { 'missing' }
        Services = $servicesText
    }
}

if (-not $RunNow -and -not $DueOnly) {
    Write-Host 'Plan only. Use -RunNow to execute immediately or -DueOnly for scheduler use.' -ForegroundColor Yellow
    $plan | Format-Table -AutoSize
    return
}

if (-not $shouldRun) {
    Write-Host "No configured schedule is due within $WindowMinutes minute(s). Nothing to run." -ForegroundColor Yellow
    $plan | Format-Table -AutoSize
    return
}

$summary = @()
foreach ($agent in $selectedAgents) {
    $status = 'success'
    $comment = ''
    try {
        $sessionPresent = Test-BrowserSession -RepoRoot $repoRoot -Sam $agent.sam
        if ($InitializeMissingSessions -or $RefreshAuth -or (-not $sessionPresent)) {
            $initArgs = @{
                Agents = @($agent.sam)
                Services = @($servicesText -split ',')
                ConfigPath = $ConfigPath
                ContinueOnFailure = $true
            }
            if ($RefreshAuth) { $initArgs.RefreshAuth = $true }
            elseif ($sessionPresent) { $initArgs.SkipAuth = $true }
            if ($Azure) { $initArgs.Azure = $true }
            & (Join-Path $repoRoot 'tools\Initialize-BrowserAgents.ps1') @initArgs
        } elseif (-not $SkipPreflight) {
            $initArgs = @{
                Agents = @($agent.sam)
                Services = @($servicesText -split ',')
                ConfigPath = $ConfigPath
                SkipAuth = $true
                ContinueOnFailure = $true
            }
            if ($Azure) { $initArgs.Azure = $true }
            & (Join-Path $repoRoot 'tools\Initialize-BrowserAgents.ps1') @initArgs
        }

        $dailyArgs = @{
            Agent = $agent.sam
            Services = @($servicesText -split ',')
            ExternalRecipient = $ExternalRecipient
            ConfigPath = $ConfigPath
        }
        if ($SendEmail) { $dailyArgs.SendEmail = $true }
        if ($Sensitive) { $dailyArgs.Sensitive = $true }
        if ($Label) { $dailyArgs.Label = $Label }
        if ($Azure) { $dailyArgs.Azure = $true }
        & (Join-Path $repoRoot 'tools\Invoke-BrowserAgentDaily.ps1') @dailyArgs
    }
    catch {
        $status = 'failed'
        $comment = $_.Exception.Message
    }

    $summary += [PSCustomObject]@{
        Agent = $agent.sam
        DisplayName = $agent.displayName
        Services = $servicesText
        Status = $status
        Comments = $comment
    }

    if ($status -eq 'failed' -and -not $ContinueOnFailure) { break }
}

if ($AdxWaitSeconds -gt 0) {
    Write-Host "`nWaiting $AdxWaitSeconds sec for ADX ingestion..." -ForegroundColor Gray
    Start-Sleep -Seconds $AdxWaitSeconds
}

Write-Host ''
Write-Host '=== BrowserAgent Scheduled Run Results ===' -ForegroundColor Cyan
$summary | Format-Table -AutoSize

Write-Host ''
& (Join-Path $repoRoot 'tools\Get-BrowserAgentTelemetry.ps1') -SinceMinutes 90 -ConfigPath $ConfigPath



