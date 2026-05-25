<#
.SYNOPSIS
    Update the configured Azure OpenAI account name in config files.
.DESCRIPTION
    Azure OpenAI custom domains are globally unique. If a configured endpoint
    resolves to another tenant, update the account name before rerunning Step 4
    and Step 5.
.EXAMPLE
    .\tools\Set-AzureOpenAIName.ps1
.EXAMPLE
    .\tools\Set-AzureOpenAIName.ps1 -Name oai-claudia-lab
#>
param(
    [string]$Name,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function New-DefaultOaiName {
    param($Config)
    $seed = "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-openai"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $suffix = ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
    $base = ($Config.infrastructure.resourceGroup -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($base.Length -gt 11) { $base = $base.Substring(0, 11) }
    return "oai-$base-$suffix"
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
if (-not $Name) { $Name = New-DefaultOaiName -Config $config }

if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{1,62}[a-zA-Z0-9]$') {
    throw "Invalid Azure OpenAI account name '$Name'. Use 3-64 letters, numbers, or hyphens, starting and ending with alphanumeric."
}

$oldName = $config.infrastructure.openAiAccountName
$config.infrastructure.openAiAccountName = $Name
$config | ConvertTo-Json -Depth 30 | Set-Content $ConfigPath -Encoding utf8

if (Test-Path $InstallationDefinitionsPath) {
    $defs = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($defs.infrastructure.PSObject.Properties['openAiAccountName']) {
        $defs.infrastructure.openAiAccountName = $Name
    } else {
        $defs.infrastructure | Add-Member -NotePropertyName openAiAccountName -NotePropertyValue $Name -Force
    }
    $defs.updatedAt = (Get-Date).ToString('o')
    $defs | ConvertTo-Json -Depth 30 | Set-Content $InstallationDefinitionsPath -Encoding utf8
}

Write-Host "Azure OpenAI account name updated." -ForegroundColor Green
Write-Host "  Old: $oldName"
Write-Host "  New: $Name"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  .\Install-AutonomousAgents.ps1 -UseExistingUsers -UseInstallationDefinitions -Step 4"
Write-Host "  .\Install-AutonomousAgents.ps1 -UseExistingUsers -UseInstallationDefinitions -Step 5"
Write-Host "  .\tests\Test-AzureOpenAI.ps1"
