<#PSScriptInfo

.VERSION 1.0.0

.GUID 204f539c-3eb6-422c-a88d-c3e07b3b0c00

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
Runs BrowserAgent smoke tests locally or in Azure Playwright Workspaces

.RELEASENOTES
Initial version metadata for Runs BrowserAgent smoke tests locally or in Azure Playwright Workspaces.

#>
<#
.SYNOPSIS
    Runs BrowserAgent smoke tests locally or in Azure Playwright Workspaces.
.EXAMPLE
    .\tools\Invoke-BrowserAgentSmoke.ps1
.EXAMPLE
    .\tools\Invoke-BrowserAgentSmoke.ps1 -Azure
#>
[CmdletBinding()]
param(
    [switch]$Azure,
    [switch]$Daily,
    [string]$BrowserAgentsPath = (Join-Path $PSScriptRoot '..\BrowserAgents')
)

$ErrorActionPreference = 'Stop'
$nodePath = 'C:\Program Files\nodejs'
if (Test-Path -LiteralPath $nodePath) {
    $env:PATH = "$nodePath;$env:PATH"
}

$npm = Join-Path $nodePath 'npm.cmd'
if (-not (Test-Path -LiteralPath $npm)) { $npm = 'npm' }

Push-Location $BrowserAgentsPath
try {
    if ($Daily -and $Azure) {
        & $npm run daily:priya:azure
    } elseif ($Daily) {
        & $npm run daily:priya
    } elseif ($Azure) {
        & $npm run office:priya:azure
    } else {
        & $npm run office:priya
    }
    if ($LASTEXITCODE -ne 0) { throw "BrowserAgent smoke test failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}



