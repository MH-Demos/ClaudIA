<#PSScriptInfo

.VERSION 1.0.0

.GUID 18e4fe13-bf23-48fe-a824-ce75e26ec23d

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
Forces a fresh Activity Story Map data refresh by running agent activity jobs

.RELEASENOTES
Initial version metadata for Forces a fresh Activity Story Map data refresh by running agent activity jobs.

#>
<#
.SYNOPSIS
    Forces a fresh Activity Story Map data refresh by running agent activity jobs.
.DESCRIPTION
    The Activity Story Map queries ADX live, so there is no separate cache to
    rebuild. This script starts agent activity runs and waits briefly for ADX
    ingestion so the map has fresh narrative data.
#>
param(
    [string[]]$Agents,
    [switch]$Parallel,
    [int]$ThrottleLimit = 5,
    [int]$ADXWaitMinutes = 2,
    [switch]$NoADXWait
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$fullRunScript = Join-Path $repoRoot 'tests\Test-FullRun.ps1'

if (-not (Test-Path -LiteralPath $fullRunScript)) {
    throw "Could not find full run script at '$fullRunScript'."
}

$arguments = @{}
if ($Agents -and $Agents.Count -gt 0) { $arguments['Agents'] = $Agents }
if ($Parallel) {
    $arguments['Parallel'] = $true
    $arguments['ThrottleLimit'] = $ThrottleLimit
}
if ($NoADXWait) {
    $arguments['NoADXWait'] = $true
} else {
    $arguments['ADXWaitMinutes'] = $ADXWaitMinutes
}

Write-Host 'Starting Activity Story Map data refresh...' -ForegroundColor Cyan
Write-Host 'The map reads ADX live; open the Story Map after this run completes.' -ForegroundColor DarkGray

& $fullRunScript @arguments



