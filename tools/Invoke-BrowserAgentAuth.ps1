<#
.SYNOPSIS
    Captures a Microsoft 365 browser session for a BrowserAgent using Key Vault credentials.
.DESCRIPTION
    Reads the selected agent password from Key Vault, injects it into the Playwright
    auth setup process as an environment variable, and removes it from the current
    process after the command completes.
.EXAMPLE
    .\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma
#>
[CmdletBinding()]
param(
    [string]$Agent = 'priya.sharma',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$BrowserAgentsPath = (Join-Path $PSScriptRoot '..\BrowserAgents')
)

$ErrorActionPreference = 'Stop'

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$agentConfig = $config.agents | Where-Object { $_.sam -eq $Agent -or $_.userPrincipalName -eq $Agent } | Select-Object -First 1
if (-not $agentConfig) { throw "Agent '$Agent' not found in config." }

$kvName = if ($config.browserAgents.keyVaultName) { $config.browserAgents.keyVaultName } elseif ($config.infrastructure.keyVaultName) { $config.infrastructure.keyVaultName } else { $config.adx.keyVaultName }
if (-not $kvName) { throw "Key Vault name not found in config." }

$secretName = if ($agentConfig.keyVaultSecretName) { $agentConfig.keyVaultSecretName } else { ($agentConfig.sam -replace '\.','-') }
$npm = 'C:\Program Files\nodejs\npm.cmd'
if (-not (Test-Path -LiteralPath $npm)) { $npm = 'npm' }

Write-Host "=== BrowserAgent Auth Capture ===" -ForegroundColor Cyan
Write-Host "  Agent:     $($agentConfig.userPrincipalName)"
Write-Host "  Key Vault: $kvName"
Write-Host "  Secret:    $secretName"
Write-Host ""

$password = az keyvault secret show --vault-name $kvName --name $secretName --query value -o tsv
if (-not $password) { throw "Secret '$secretName' is empty or could not be read from Key Vault '$kvName'." }

Push-Location $BrowserAgentsPath
try {
    $env:BROWSER_AGENT_PERSONA = $agentConfig.sam
    $env:BROWSER_AGENT_UPN = $agentConfig.userPrincipalName
    $env:BROWSER_AGENT_DISPLAY_NAME = $agentConfig.displayName
    $env:BROWSER_AGENT_STORAGE_STATE = ".auth/$($agentConfig.sam).json"
    $env:BROWSER_AGENT_PASSWORD = $password

    if (Test-Path -LiteralPath $env:BROWSER_AGENT_STORAGE_STATE) {
        Remove-Item -LiteralPath $env:BROWSER_AGENT_STORAGE_STATE -Force
    }

    & $npm run auth:priya
    if ($LASTEXITCODE -ne 0) { throw "BrowserAgent auth capture failed with exit code $LASTEXITCODE." }
}
finally {
    $env:BROWSER_AGENT_PASSWORD = $null
    Pop-Location
}
