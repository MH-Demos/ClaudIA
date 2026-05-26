<#PSScriptInfo

.VERSION 1.0.0

.GUID b94087f0-e35b-4a85-94fd-c5aebc04ea68

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
List chat-completion Azure OpenAI models available for the configured account

.RELEASENOTES
Initial version metadata for List chat-completion Azure OpenAI models available for the configured account.

#>
<#
.SYNOPSIS
    List chat-completion Azure OpenAI models available for the configured account.
.EXAMPLE
    .\tools\List-AzureOpenAIModels.ps1
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

az account set -s $config.tenant.subscriptionId 2>$null
$models = @(az cognitiveservices account list-models `
    -n $config.infrastructure.openAiAccountName `
    -g $config.infrastructure.resourceGroup `
    -o json | ConvertFrom-Json)
$usage = @(az cognitiveservices usage list -l $config.tenant.location -o json | ConvertFrom-Json)
$quotaMap = @{}
foreach ($item in $usage) {
    if ($item.name.value -like 'OpenAI.Standard.*') {
        $quotaMap[$item.name.value] = [pscustomobject]@{
            Current = [double]$item.currentValue
            Limit = [double]$item.limit
            Available = [double]$item.limit - [double]$item.currentValue
        }
    }
}

function Get-StandardQuotaKey {
    param([string]$ModelName)
    switch ($ModelName) {
        'gpt-4.1' { return 'OpenAI.Standard.gpt4.1' }
        'gpt-4.1-mini' { return 'OpenAI.Standard.gpt4.1-mini' }
        'gpt-4.1-nano' { return 'OpenAI.Standard.gpt4.1-nano' }
        'gpt-4o' { return 'OpenAI.Standard.gpt-4o' }
        'gpt-4o-mini' { return 'OpenAI.Standard.gpt-4o-mini' }
        'gpt-5.1' { return 'OpenAI.Standard.gpt-5.1' }
        'gpt-5' { return 'OpenAI.Standard.gpt-5' }
        'o4-mini' { return 'OpenAI.Standard.o4-mini' }
        'o1' { return 'OpenAI.Standard.o1' }
        default { return "OpenAI.Standard.$ModelName" }
    }
}

function Test-ImageModelCandidate {
    param($Model)
    return (
        $Model.format -eq 'OpenAI' -and
        (
            $Model.capabilities.imageGenerations -eq 'true' -or
            $Model.capabilities.imageGeneration -eq 'true' -or
            $Model.capabilities.imagesGenerations -eq 'true' -or
            $Model.name -match 'dall|image'
        ) -and
        @($Model.skus | Where-Object { $_.name -eq 'Standard' }).Count -gt 0
    )
}

$chatModels = @($models | Where-Object {
    $_.format -eq 'OpenAI' -and
    $_.capabilities.chatCompletion -eq 'true' -and
    @($_.skus | Where-Object { $_.name -eq 'Standard' }).Count -gt 0
} | Sort-Object @{Expression = { $_.lifecycleStatus -ne 'GenerallyAvailable' }}, name, version)

$imageModels = @($models | Where-Object { Test-ImageModelCandidate $_ } |
    Sort-Object @{Expression = { $_.lifecycleStatus -ne 'GenerallyAvailable' }}, name, version)

Write-Host "Azure OpenAI chat models for $($config.infrastructure.openAiAccountName) in $($config.infrastructure.resourceGroup):" -ForegroundColor Cyan
for ($i = 0; $i -lt $chatModels.Count; $i++) {
    $m = $chatModels[$i]
    $skus = ($m.skus | ForEach-Object { $_.name } | Select-Object -Unique) -join ','
    $standard = $m.skus | Where-Object { $_.name -eq 'Standard' } | Select-Object -First 1
    $max = if ($standard.capacity.maximum) { $standard.capacity.maximum } else { $m.maxCapacity }
    $quotaKey = Get-StandardQuotaKey -ModelName $m.name
    $quota = if ($quotaMap.ContainsKey($quotaKey)) { $quotaMap[$quotaKey] } else { $null }
    $quotaText = if ($quota) { "quota=$($quota.Current)/$($quota.Limit), available=$($quota.Available)" } else { "quota=unknown" }
    Write-Host ("  [{0}] {1} | version={2} | {3} | default={4} | standardMax={5} | {6} | skus={7}" -f ($i + 1), $m.name, $m.version, $m.lifecycleStatus, $m.isDefaultVersion, $max, $quotaText, $skus)
}

Write-Host ""
Write-Host "Azure OpenAI image models for $($config.infrastructure.openAiAccountName) in $($config.infrastructure.resourceGroup):" -ForegroundColor Cyan
if ($imageModels.Count -eq 0) {
    Write-Host "  [none] No Standard image-generation model is available in this account/region." -ForegroundColor Yellow
} else {
    for ($i = 0; $i -lt $imageModels.Count; $i++) {
        $m = $imageModels[$i]
        $skus = ($m.skus | ForEach-Object { $_.name } | Select-Object -Unique) -join ','
        $standard = $m.skus | Where-Object { $_.name -eq 'Standard' } | Select-Object -First 1
        $max = if ($standard.capacity.maximum) { $standard.capacity.maximum } else { $m.maxCapacity }
        $defaultCapacity = if ($standard.capacity.default) { $standard.capacity.default } else { 1 }
        Write-Host ("  [{0}] {1} | version={2} | {3} | default={4} | standardDefault={5} | standardMax={6} | skus={7}" -f ($i + 1), $m.name, $m.version, $m.lifecycleStatus, $m.isDefaultVersion, $defaultCapacity, $max, $skus)
    }
}



