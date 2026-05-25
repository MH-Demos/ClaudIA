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
