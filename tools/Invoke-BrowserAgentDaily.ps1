<#
.SYNOPSIS
    Run real browser-based daily activity for one BrowserAgent.
.EXAMPLE
    .\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa,copilot
.EXAMPLE
    .\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa -ExternalRecipient demo.recipient@example.com -SendEmail -Sensitive -Label General
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Agent,
    [string[]]$Services = @('owa','copilot','banking'),
    [string]$ExternalRecipient = '',
    [switch]$SendEmail,
    [switch]$Sensitive,
    [string]$Label = '',
    [switch]$Azure,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$BrowserAgentsPath = (Join-Path $PSScriptRoot '..\BrowserAgents')
)

$ErrorActionPreference = 'Stop'

function Resolve-NodeCommand {
    param([string]$Name)
    $nodePath = 'C:\Program Files\nodejs'
    if (Test-Path -LiteralPath $nodePath) { $env:PATH = "$nodePath;$env:PATH" }
    $candidate = Join-Path $nodePath "$Name.cmd"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $Name
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$agentConfig = $config.agents | Where-Object {
    $_.sam -eq $Agent -or $_.userPrincipalName -eq $Agent -or $_.displayName -eq $Agent
} | Select-Object -First 1
if (-not $agentConfig) { throw "Agent '$Agent' not found in config." }

$serviceAliases = (($Services -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
if ($serviceAliases.Count -eq 0) { throw 'No BrowserAgent services selected.' }

$testFiles = [System.Collections.Generic.List[string]]::new()
foreach ($service in $serviceAliases) {
    switch ($service) {
        { $_ -in @('owa','outlook','mail','email','exchange') } {
            if (-not $testFiles.Contains('tests/owa-daily-activity.spec.js')) { $testFiles.Add('tests/owa-daily-activity.spec.js') }
            break
        }
        { $_ -in @('copilot','chat','m365copilot','m365 copilot','copilotchat','copilot chat') } {
            if (-not $testFiles.Contains('tests/m365-copilot-daily-activity.spec.js')) { $testFiles.Add('tests/m365-copilot-daily-activity.spec.js') }
            break
        }
        { $_ -in @('internalai','internal-ai','externalai','external ai','foundry','azure ai foundry','deepseek','claude','grok','llama','gemini') } {
            if (-not $testFiles.Contains('tests/internal-ai-portal.spec.js')) { $testFiles.Add('tests/internal-ai-portal.spec.js') }
            if ($_ -in @('deepseek','claude','grok','llama','gemini')) { $env:BROWSER_AGENT_INTERNAL_AI_MODEL = $_ }
            break
        }
        { $_ -in @('banking','banking-wave1','finance','bf-wave1') } {
            if (-not $testFiles.Contains('tests/banking-finance-wave1.spec.js')) { $testFiles.Add('tests/banking-finance-wave1.spec.js') }
            break
        }
        default {
            throw "BrowserAgent service '$service' is not implemented yet. Supported: owa, copilot, internalai, banking."
        }
    }
}

$npx = Resolve-NodeCommand -Name 'npx'
$storageState = ".auth/$($agentConfig.sam).json"
$storageStatePath = Join-Path $BrowserAgentsPath $storageState
if (-not (Test-Path -LiteralPath $storageStatePath)) {
    throw "Browser session state '$storageState' does not exist. Run .\tools\Initialize-BrowserAgents.ps1 -Agents $($agentConfig.sam) first."
}

Write-Host "=== BrowserAgent Daily Activity ===" -ForegroundColor Cyan
Write-Host "  Agent:    $($agentConfig.displayName) <$($agentConfig.userPrincipalName)>"
Write-Host "  Services: $($serviceAliases -join ',')"
Write-Host "  Mode:     $(if ($Azure) { 'Azure Playwright Workspace' } else { 'local browser' })"
if ($ExternalRecipient) { Write-Host "  External: $ExternalRecipient" }
Write-Host ""

$env:BROWSER_AGENT_PERSONA = [string]$agentConfig.sam
$env:BROWSER_AGENT_UPN = [string]$agentConfig.userPrincipalName
$env:BROWSER_AGENT_DISPLAY_NAME = [string]$agentConfig.displayName
$env:BROWSER_AGENT_STORAGE_STATE = $storageState
$env:BROWSER_AGENT_SEND_EMAIL = if ($SendEmail) { 'true' } else { 'false' }
$env:BROWSER_AGENT_INCLUDE_SENSITIVE = if ($Sensitive) { 'true' } else { 'false' }
if ($ExternalRecipient) { $env:BROWSER_AGENT_EMAIL_RECIPIENT = $ExternalRecipient }
if ($Label) { $env:BROWSER_AGENT_EMAIL_LABEL = $Label } else { Remove-Item Env:\BROWSER_AGENT_EMAIL_LABEL -ErrorAction SilentlyContinue }

Push-Location $BrowserAgentsPath
try {
    $args = @('playwright','test') + $testFiles
    if ($Azure) {
        $args += @('-c','playwright.azure.config.js')
    } else {
        $args += @('--project=chromium')
    }
    & $npx @args
    if ($LASTEXITCODE -ne 0) { throw "BrowserAgent daily activity failed with exit code $LASTEXITCODE." }
}
finally {
    Pop-Location
}
