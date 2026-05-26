<#PSScriptInfo

.VERSION 1.0.1

.GUID e466171f-02d2-431e-b803-bea994eb5cde

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
Validate the Azure OpenAI deployment used by the runbook

.RELEASENOTES
Version 1.0.1 explains current-user RBAC failures separately from runbook managed identity access.

#>
<#
.SYNOPSIS
    Validate the Azure OpenAI deployment used by the runbook.
.DESCRIPTION
    Uses the current Azure CLI identity to request a Cognitive Services token and
    calls the configured chat completions deployment with a minimal prompt. This
    isolates Azure OpenAI API/deployment errors from runbook execution.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$Prompt = 'Write one short sentence in English for a lab test.'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

$sub = $config.tenant.subscriptionId
$account = $config.infrastructure.openAiAccountName
$deployment = $config.infrastructure.openAiModel
$modelVersion = $config.infrastructure.openAiModelVersion
$endpoint = "https://$account.openai.azure.com/"

if ($sub) { az account set -s $sub 2>$null }
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Cognitive Services token through Azure CLI." }

$body = @{
    messages = @(
        @{ role = 'system'; content = 'You are a concise test assistant.' }
        @{ role = 'user'; content = $Prompt }
    )
    max_tokens = 80
    temperature = 0.2
    user = 'diagnostic@test'
} | ConvertTo-Json -Depth 5

Write-Host "=== Azure OpenAI Validation ===" -ForegroundColor Cyan
Write-Host "  Subscription: $sub"
Write-Host "  Endpoint:     $endpoint"
Write-Host "  Deployment:   $deployment"
if ($modelVersion) { Write-Host "  ModelVersion: $modelVersion" }
Write-Host ""

$accountId = az cognitiveservices account show -n $account -g $config.infrastructure.resourceGroup --query id -o tsv 2>$null
$currentPrincipalId = az ad signed-in-user show --query id -o tsv 2>$null
$roleAssignments = @()
if ($accountId) {
    $roleAssignments = @(az role assignment list --scope $accountId --query "[].{principalId:principalId,role:roleDefinitionName}" -o json 2>$null | ConvertFrom-Json)
}

$apiVersions = @('2024-10-21','2024-08-01-preview','2024-02-01')
foreach ($apiVersion in $apiVersions) {
    $uri = "${endpoint}openai/deployments/${deployment}/chat/completions?api-version=$apiVersion"
    Write-Host "Testing api-version $apiVersion..." -NoNewline
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -Body $body -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
        Write-Host "  Response: $($resp.choices[0].message.content)" -ForegroundColor Gray
        return
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  $details" -ForegroundColor Yellow
        if ($details -match 'PermissionDenied' -and $accountId) {
            $currentHasOpenAiRole = @($roleAssignments | Where-Object {
                $_.principalId -eq $currentPrincipalId -and $_.role -match 'Cognitive Services OpenAI|Cognitive Services Contributor|Owner|Contributor'
            }).Count -gt 0
            if (-not $currentHasOpenAiRole) {
                Write-Host "  The current Azure CLI user does not have Azure OpenAI data-plane access on this account." -ForegroundColor Yellow
                Write-Host "  This blocks this local test, but the runbook can still work if the Automation managed identity has 'Cognitive Services OpenAI User'." -ForegroundColor Yellow
                Write-Host "  Fix for local validation: assign 'Cognitive Services OpenAI User' to the signed-in user on $account." -ForegroundColor Yellow
            }
        }
    }
}

throw "Azure OpenAI validation failed for all tested API versions."



