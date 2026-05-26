<#PSScriptInfo

.VERSION 1.0.0

.GUID 8ed907ad-2549-448c-83c8-ef880598982c

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
Reset configured agent passwords and synchronize their Key Vault secrets

.RELEASENOTES
Initial version metadata for Reset configured agent passwords and synchronize their Key Vault secrets.

#>
<#
.SYNOPSIS
    Reset configured agent passwords and synchronize their Key Vault secrets.
.DESCRIPTION
    Resets one, many, or all configured agent users to a generated/shared lab
    password, stores each per-agent password secret in Key Vault, and updates
    Automation variables that point the runbook to those secret names.

    Use this after an expansion or after an accidental shared-password overwrite
    to bring Entra ID, Key Vault, and Automation back into alignment.
.EXAMPLE
    .\tools\Reset-AgentPasswords.ps1 -All
.EXAMPLE
    .\tools\Reset-AgentPasswords.ps1 -Agent sofia.lopez -RevealPassword
.EXAMPLE
    .\tools\Reset-AgentPasswords.ps1 -All -AgentPassword 'LabPassword123!'
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string[]]$Agent,
    [switch]$All,
    [string]$AgentPassword,
    [switch]$RevealPassword,
    [switch]$SkipAutomationVariables
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function New-LabPassword {
    -join ((65..90) + (97..122) + (48..57) + (33,35,36,37) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
}

function Set-AutomationVariable {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    az account set -s $SubscriptionId 2>$null
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Could not acquire Azure management token." }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $jsonValue = $Value | ConvertTo-Json -Compress
    $body = @{ properties = @{ value = $jsonValue; isEncrypted = $true } } | ConvertTo-Json -Depth 4 -Compress
    $uri = "https://management.azure.com/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroup}/providers/Microsoft.Automation/automationAccounts/${AutomationAccountName}/variables/${Name}?api-version=2023-11-01"
    Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

if (-not $All -and (-not $Agent -or $Agent.Count -eq 0)) {
    throw "Specify -All or one or more -Agent values."
}

$domain = $config.tenant.domain
$selectedAgents = if ($All) {
    @($config.agents)
} else {
    @($config.agents | Where-Object {
        $upn = Get-AgentUpn -Agent $_ -Domain $domain
        $Agent -contains $_.sam -or $Agent -contains $upn -or $Agent -contains $_.displayName
    })
}
if (-not $selectedAgents -or $selectedAgents.Count -eq 0) {
    throw "No matching agents found."
}

if (-not $AgentPassword) { $AgentPassword = New-LabPassword }
$sub = $config.tenant.subscriptionId
$rg = $config.infrastructure.resourceGroup
$aaName = $config.infrastructure.automationAccountName
$kvName = Get-KeyVaultName -Config $config

az account set -s $sub 2>$null

Write-Host "=== Reset Agent Passwords ===" -ForegroundColor Cyan
Write-Host "  Agents:      $($selectedAgents.Count)"
Write-Host "  Key Vault:   $kvName"
Write-Host "  Automation:  $aaName"
Write-Host ""

$resetOk = 0
$secretOk = 0
foreach ($agentInfo in $selectedAgents) {
    $upn = Get-AgentUpn -Agent $agentInfo -Domain $domain
    $secretName = Get-AgentSecretName -Agent $agentInfo -Domain $domain

    Write-Host "  Resetting $upn..." -NoNewline
    az ad user update --id $upn --password $AgentPassword --force-change-password-next-sign-in false -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        $resetOk++
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
        continue
    }

    Write-Host "    Storing Key Vault secret '$secretName'..." -NoNewline
    az keyvault secret set --vault-name $kvName --name $secretName --value $AgentPassword -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        $secretOk++
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [FAIL]" -ForegroundColor Red
    }
}

if (-not $SkipAutomationVariables) {
    Write-Host "  Updating Automation secret-name variables..." -NoNewline
    foreach ($agentInfo in $selectedAgents) {
        $secretName = Get-AgentSecretName -Agent $agentInfo -Domain $domain
        Set-AutomationVariable -SubscriptionId $sub -ResourceGroup $rg -AutomationAccountName $aaName -Name "AgentPwdSecret-$($agentInfo.sam)" -Value $secretName
    }
    $configJson = $config | ConvertTo-Json -Depth 50
    Set-AutomationVariable -SubscriptionId $sub -ResourceGroup $rg -AutomationAccountName $aaName -Name 'AgentConfig' -Value $configJson
    Write-Host " [OK]" -ForegroundColor Green
}

Write-Host ""
Write-Host "Password reset complete: $resetOk/$($selectedAgents.Count) users, $secretOk/$($selectedAgents.Count) secrets." -ForegroundColor Green
if ($RevealPassword) {
    Write-Host "Shared lab password: $AgentPassword" -ForegroundColor Yellow
}



