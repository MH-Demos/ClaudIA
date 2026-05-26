<#PSScriptInfo

.VERSION 1.0.0

.GUID 0216918c-f720-4dd8-bf40-d087c0b78cf5

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
Enables or disables ClaudIA Microsoft 365 Copilot-specific tasks

.RELEASENOTES
Initial version metadata for Enables or disables ClaudIA Microsoft 365 Copilot-specific tasks.

#>
<#
.SYNOPSIS
    Enables or disables ClaudIA Microsoft 365 Copilot-specific tasks.
.DESCRIPTION
    Toggles features.copilotQueries in config\agents.json. This controls
    runbook tasks that emulate Microsoft 365 Copilot queries for agents marked
    with copilotLicense=true.

    Non-Copilot AI emulation, such as ExternalAI scenarios through Azure AI
    Foundry, is controlled separately by features.externalAiInteractions and is
    not changed by this script.
.EXAMPLE
    .\tools\Set-CopilotTasks.ps1 -Mode Disable
.EXAMPLE
    .\tools\Set-CopilotTasks.ps1 -Mode Enable
#>
[CmdletBinding()]
param(
    [ValidateSet('Enable','Disable')]
    [string]$Mode = 'Enable',

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.PSObject.Properties['features'] -or -not $config.features) {
    $config | Add-Member -NotePropertyName features -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$enabled = ($Mode -eq 'Enable')
if ($config.features.PSObject.Properties['copilotQueries']) {
    $config.features.copilotQueries = $enabled
} else {
    $config.features | Add-Member -NotePropertyName copilotQueries -NotePropertyValue $enabled -Force
}

$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding utf8

$copilotAgents = @($config.agents | Where-Object { $_.copilotLicense -eq $true })
$externalAiState = if ($config.features.externalAiInteractions -eq $false) { 'disabled' } else { 'enabled' }

Write-Host "ClaudIA Copilot tasks: $Mode" -ForegroundColor Green
Write-Host "Config updated: $ConfigPath" -ForegroundColor Gray
Write-Host "Copilot-marked agents: $($copilotAgents.Count)" -ForegroundColor Gray
Write-Host "ExternalAI/non-Copilot AI emulation remains $externalAiState." -ForegroundColor Gray

if ($enabled) {
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Assign Microsoft 365 Copilot licenses to the Copilot-marked agents." -ForegroundColor Gray
    Write-Host "  2. Rerun Install-ClaudIA.ps1 Step 5 or Publish-RunbookOnly.ps1 so Automation receives the updated config." -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "Copilot-specific runbook tasks are disabled until licenses are available." -ForegroundColor Yellow
}



