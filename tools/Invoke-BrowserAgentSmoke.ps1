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
