<#PSScriptInfo

.VERSION 1.0.0

.GUID 8b187ba4-2203-4ffe-9328-fc941d0b8771

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
Validate app-claudia-dataagent client secret and one agent password from Key Vault

.RELEASENOTES
Initial version metadata for Validate app-claudia-dataagent client secret and one agent password from Key Vault.

#>
<#
.SYNOPSIS
    Validate app-claudia-dataagent client secret and one agent password from Key Vault.
.DESCRIPTION
    Reads the existing project config/installation definitions, resolves the selected
    agent UPN and Key Vault secret names, then validates:
      - app-claudia-dataagent client secret can obtain a client_credentials token
      - agent password can obtain a delegated ROPC Graph token

    By default it never prints secret values. Use -RevealSecretValues only in a lab.
.EXAMPLE
    .\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez
.EXAMPLE
    .\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez -ExpectedClientSecret 'value' -RevealSecretValues
#>
param(
    [Parameter(Mandatory)]
    [string]$Agent,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),

    [string]$ExpectedClientSecret,
    [string]$ExpectedPassword,

    [switch]$RepairConsent,
    [switch]$RevealSecretValues
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function ConvertTo-FormBody {
    param([hashtable]$Body)
    ($Body.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [System.Net.WebUtility]::UrlEncode([string]$_.Key), [System.Net.WebUtility]::UrlEncode([string]$_.Value)
    }) -join '&'
}

function Write-Check {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    $status = if ($Ok) { '[OK]' } else { '[FAIL]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0} {1}" -f $status, $Label) -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

function Get-PlainSecret {
    param([string]$VaultName, [string]$SecretName)
    $value = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Could not read Key Vault secret '$SecretName' from '$VaultName'."
    }
    return $value
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
$definitions = $effective.Definitions

$domain = $config.tenant.domain
$subscriptionId = $config.tenant.subscriptionId
$tenantId = az account show --query tenantId -o tsv 2>$null
if (-not $tenantId) { throw "Azure CLI is not logged in. Run 'az login' first." }
if ($subscriptionId) { az account set -s $subscriptionId 2>$null }

$agentInfo = $config.agents | Where-Object {
    $_.sam -eq $Agent -or $_.userPrincipalName -eq $Agent -or $_.upn -eq $Agent
} | Select-Object -First 1
if (-not $agentInfo) { throw "Agent '$Agent' not found in $ConfigPath." }

$agentUpn = Get-AgentUpn -Agent $agentInfo -Domain $domain
$agentSecretName = Get-AgentSecretName -Agent $agentInfo -Domain $domain
$keyVaultName = Get-KeyVaultName -Config $config

$appId = $null
if ($definitions -and $definitions.steps.'3'.appId) { $appId = $definitions.steps.'3'.appId }
if (-not $appId) {
    $appId = az ad app list --display-name 'app-claudia-dataagent' --query "[0].appId" -o tsv 2>$null
}
if (-not $appId) { throw "Could not resolve app-claudia-dataagent appId." }

Write-Host "=== Agent Credential Validation ===" -ForegroundColor Cyan
Write-Host "  Tenant:       $tenantId"
Write-Host "  Subscription: $subscriptionId"
Write-Host "  Key Vault:    $keyVaultName"
Write-Host "  AppId:        $appId"
Write-Host "  Agent:        $agentUpn"
Write-Host "  Secret names: agent-client-secret, $agentSecretName"
Write-Host ""

if ($RepairConsent) {
    Write-Host "Repairing app delegated consent..." -ForegroundColor Cyan
    try {
        $grantInfo = Ensure-AADataAgentGraphConsent -AppId $appId
        Write-Check "Delegated Graph consent repaired" $true "tenantGrant=$($grantInfo.TenantGrantId); principalGrants=$($grantInfo.ExistingPrincipalGrantCount); scope=$($grantInfo.Scope)"
    } catch {
        Write-Check "Delegated Graph consent repaired" $false $_.Exception.Message
    }
    Write-Host ""
}

$clientSecret = Get-PlainSecret -VaultName $keyVaultName -SecretName 'agent-client-secret'
$agentPassword = Get-PlainSecret -VaultName $keyVaultName -SecretName $agentSecretName

Write-Check "Read app client secret from Key Vault" ($clientSecret.Length -gt 0) "length=$($clientSecret.Length)"
Write-Check "Read agent password from Key Vault" ($agentPassword.Length -gt 0) "length=$($agentPassword.Length)"

if ($ExpectedClientSecret) {
    Write-Check "Client secret matches expected value" ($clientSecret -eq $ExpectedClientSecret)
}
if ($ExpectedPassword) {
    Write-Check "Agent password matches expected value" ($agentPassword -eq $ExpectedPassword)
}
if ($RevealSecretValues) {
    Write-Host ""
    Write-Host "  [LAB] agent-client-secret value: $clientSecret" -ForegroundColor Yellow
    Write-Host "  [LAB] $agentSecretName value: $agentPassword" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Testing app-only token..." -ForegroundColor Cyan
try {
    $clientBody = ConvertTo-FormBody @{
        client_id     = $appId
        client_secret = $clientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    $clientToken = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body $clientBody -ErrorAction Stop
    Write-Check "client_credentials token acquired" ([bool]$clientToken.access_token) "expires_in=$($clientToken.expires_in)"
} catch {
    $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Check "client_credentials token acquired" $false $msg
}

Write-Host ""
Write-Host "Testing ROPC delegated token..." -ForegroundColor Cyan
$ropcScopes = @(
    'https://graph.microsoft.com/.default',
    'openid offline_access Files.ReadWrite.All Sites.ReadWrite.All Mail.Send Chat.ReadWrite ChannelMessage.Send Team.ReadBasic.All Chat.Create User.Read InformationProtectionPolicy.Read'
)
$ropcOk = $false
$ropcAccessToken = $null
$lastRopcError = $null
foreach ($scope in $ropcScopes) {
    try {
        $ropcBody = ConvertTo-FormBody @{
            grant_type    = 'password'
            client_id     = $appId
            client_secret = $clientSecret
            username      = $agentUpn
            password      = $agentPassword
            scope         = $scope
        }
        $ropcToken = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body $ropcBody -ErrorAction Stop
        Write-Check "ROPC Graph token acquired" ([bool]$ropcToken.access_token) "scope=$scope; expires_in=$($ropcToken.expires_in)"
        $ropcOk = $true
        $ropcAccessToken = $ropcToken.access_token
        break
    } catch {
        $lastRopcError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Check "ROPC Graph token acquired with scope '$scope'" $false $lastRopcError
    }
}
if (-not $ropcOk) {
    Write-Check "ROPC Graph token acquired" $false $lastRopcError
} else {
    Write-Host ""
    Write-Host "Testing sensitivity label policy access..." -ForegroundColor Cyan
    try {
        $labelResp = Invoke-RestMethod -Method GET `
            -Uri 'https://graph.microsoft.com/beta/me/informationProtection/policy/labels' `
            -Headers @{ Authorization = "Bearer $ropcAccessToken" } -ErrorAction Stop
        $labelCount = @($labelResp.value).Count
        $labelNames = (@($labelResp.value) | Select-Object -First 5 | ForEach-Object { if ($_.displayName) { $_.displayName } else { $_.name } }) -join ', '
        Write-Check "Sensitivity labels visible to agent" ($labelCount -gt 0) "count=$labelCount; sample=$labelNames"
    } catch {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Check "Sensitivity labels visible to agent" $false $msg
    }
}



