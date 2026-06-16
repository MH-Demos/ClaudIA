<#PSScriptInfo

.VERSION 1.0.0

.GUID 5e9d7a2b-1f8c-4a3d-9b7e-2c4f6a8d1e0f

.AUTHOR
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Azure MCAPS Hardening publicNetworkAccess

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Daily reachability restore for ClaudIA Azure resources in MCAPS / Microsoft
Managed Environment / hardened test tenants. Idempotently flips
properties.publicNetworkAccess back to 'Enabled' on Key Vault, Azure OpenAI,
Automation Account and Azure Data Explorer, and starts the ADX cluster if it
has auto-stopped. Designed to run either locally (az CLI) or inside an Azure
Automation runbook (-UseAutomationManagedIdentity).
#>

<#
.SYNOPSIS
    Restore public network access (and ADX running state) on ClaudIA Azure
    resources. Intended to run daily in hardened tenants.

.DESCRIPTION
    Hardened tenants (MCAPS, Microsoft Managed Environment, hardened test
    tenants) apply Azure Policy on a daily schedule that flips
    properties.publicNetworkAccess back to 'Disabled' on Key Vault, Cognitive
    Services, Automation Account, Storage and Kusto/ADX. ADX Dev/Basic SKU
    clusters also auto-stop after ~5 days of inactivity.

    Without daily automation the lab degrades overnight: Key Vault writes
    return ForbiddenByConnection, the agent runbook fails to read secrets,
    ADX ingestion + queries stop, and Azure OpenAI / Automation control-plane
    writes hit network-deny.

    This script re-applies the wizard's reachability state by:
      1. PATCHing publicNetworkAccess=Enabled on each ClaudIA resource.
      2. POSTing /start on the ADX cluster if its state is Stopped.

    The script is idempotent: resources that are already Enabled (or already
    Running for ADX) are skipped silently.

.PARAMETER ResourceGroup
    Resource group that holds the ClaudIA resources (e.g. rg-claudia-lab).

.PARAMETER KeyVaultName
    Optional. Key Vault name. Omit to read it from Installation_definitions.json.

.PARAMETER OpenAiAccountName
    Optional. Azure OpenAI account name. Omit to read it from
    Installation_definitions.json.

.PARAMETER AutomationAccountName
    Optional. Automation Account name. Omit to read it from
    Installation_definitions.json.

.PARAMETER AdxClusterName
    Optional. ADX cluster name. Omit to read it from Installation_definitions.json.

.PARAMETER StorageAccountNames
    Optional. One or more storage account names to reconcile. Omit to auto-discover
    every storage account in the resource group (covers the Activity Story Map static
    site + Function host storage, whose publicNetworkAccess is flipped back to Disabled
    nightly by Azure Policy on hardened tenants).

.PARAMETER SkipStorage
    When set, storage accounts are not reconciled (Key Vault / OpenAI / Automation / ADX
    only).

.PARAMETER InstallationDefinitionsPath
    Path to Installation_definitions.json. Defaults to
    config/Installation_definitions.json relative to the script location.

.PARAMETER UseAutomationManagedIdentity
    When set, authenticates with the Azure Automation account's system-assigned
    managed identity (Connect-AzAccount -Identity) instead of az CLI. Required
    when this script is uploaded as a runbook and scheduled inside Azure
    Automation. Local runs do not set this switch.

.EXAMPLE
    # Local run, reads names from Installation_definitions.json
    .\Restore-LabPublicNetworkAccess.ps1 -ResourceGroup rg-claudia-lab

.EXAMPLE
    # Local run, explicit names
    .\Restore-LabPublicNetworkAccess.ps1 -ResourceGroup rg-claudia-lab `
        -KeyVaultName kvclaudialab -OpenAiAccountName oai-claudia-lab `
        -AutomationAccountName aa-claudia-lab -AdxClusterName adxclaudialab

.EXAMPLE
    # Inside an Azure Automation runbook on a daily schedule
    .\Restore-LabPublicNetworkAccess.ps1 -ResourceGroup rg-claudia-lab `
        -UseAutomationManagedIdentity
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$KeyVaultName,
    [string]$OpenAiAccountName,
    [string]$AutomationAccountName,
    [string]$AdxClusterName,
    [string[]]$StorageAccountNames,
    [switch]$SkipStorage,
    [string]$InstallationDefinitionsPath,
    [bool]$UseAutomationManagedIdentity = $false
)

$ErrorActionPreference = 'Stop'
$script:Flipped = [System.Collections.ArrayList]::new()
$script:Started = [System.Collections.ArrayList]::new()

function Resolve-FromDefinitions {
    if ($KeyVaultName -and $OpenAiAccountName -and $AutomationAccountName -and $AdxClusterName) { return }
    if (-not $InstallationDefinitionsPath) {
        $InstallationDefinitionsPath = Join-Path $PSScriptRoot '..\config\Installation_definitions.json'
    }
    if (-not (Test-Path $InstallationDefinitionsPath)) {
        if ($KeyVaultName -and $OpenAiAccountName -and $AutomationAccountName -and $AdxClusterName) { return }
        throw "Installation_definitions.json not found at '$InstallationDefinitionsPath' and not all resource names were supplied as parameters."
    }
    $defs = Get-Content $InstallationDefinitionsPath -Raw | ConvertFrom-Json
    $infra = $defs.infrastructure
    if (-not $KeyVaultName -and $infra.keyVaultName) { $script:KeyVaultName = $infra.keyVaultName }
    if (-not $OpenAiAccountName -and $infra.openAiAccountName) { $script:OpenAiAccountName = $infra.openAiAccountName }
    if (-not $AutomationAccountName -and $infra.automationAccountName) { $script:AutomationAccountName = $infra.automationAccountName }
    if (-not $AdxClusterName -and $defs.adx -and $defs.adx.clusterName) { $script:AdxClusterName = $defs.adx.clusterName }
}

function Get-Token {
    if ($UseAutomationManagedIdentity) {
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not (Get-AzContext)) { Connect-AzAccount -Identity | Out-Null }
        return (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
    } else {
        $tok = az account get-access-token --resource 'https://management.azure.com/' --query accessToken -o tsv
        if (-not $tok) { throw "az account get-access-token returned no token. Run 'az login' first." }
        return $tok
    }
}

function Get-SubscriptionId {
    if ($UseAutomationManagedIdentity) {
        return (Get-AzContext).Subscription.Id
    } else {
        return az account show --query id -o tsv
    }
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Url,
        [string]$Token,
        $Body
    )
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    if ($Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $json
    }
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers
}

function Enable-Pna {
    param(
        [string]$Token,
        [string]$ResourceId,
        [string]$ApiVersion,
        [string]$ResourceTypeLabel,
        [string]$Name
    )
    $url = "https://management.azure.com${ResourceId}?api-version=${ApiVersion}"
    try {
        $current = Invoke-Arm -Method GET -Url $url -Token $Token
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  [SKIP] $ResourceTypeLabel '$Name' not found (404)." -ForegroundColor DarkGray
            return
        }
        throw
    }
    $pna = $current.properties.publicNetworkAccess
    if (-not $pna) { Write-Host "  [SKIP] $ResourceTypeLabel '$Name' does not expose publicNetworkAccess." -ForegroundColor DarkGray; return }
    if ($pna -eq 'Enabled') { Write-Host "  [OK] $ResourceTypeLabel '$Name' already Enabled." -ForegroundColor DarkGray; return }

    Write-Host "  [INFO] $ResourceTypeLabel '$Name' is '$pna'. Re-enabling..." -ForegroundColor Yellow
    Invoke-Arm -Method PATCH -Url $url -Token $Token -Body @{ properties = @{ publicNetworkAccess = 'Enabled' } } | Out-Null
    [void]$script:Flipped.Add("$ResourceTypeLabel $Name")
    Write-Host "  [OK] $ResourceTypeLabel '$Name' publicNetworkAccess set to Enabled." -ForegroundColor Green
}

function Get-StorageAccountNamesInRg {
    param([string]$Token, [string]$SubscriptionId)
    # ARM enumeration keeps this self-contained inside the Automation sandbox
    # (no Installation_definitions.json present there). The Automation MI already
    # holds Contributor on the resource group.
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01"
    try {
        $resp = Invoke-Arm -Method GET -Url $url -Token $Token
        return @($resp.value | ForEach-Object { $_.name })
    } catch {
        Write-Host "  [SKIP] Could not list storage accounts in '$ResourceGroup': $($_.Exception.Message)" -ForegroundColor DarkGray
        return @()
    }
}

function Enable-StoragePna {
    param(
        [string]$Token,
        [string]$SubscriptionId,
        [string]$Name
    )
    # Storage exposes BOTH properties.publicNetworkAccess and a networkAcls.defaultAction
    # firewall. The static-website $web endpoint is served + uploaded over the public blob
    # endpoint, so both must be open for the lab to stay reachable.
    $rid = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$Name"
    $url = "https://management.azure.com${rid}?api-version=2023-01-01"
    try {
        $current = Invoke-Arm -Method GET -Url $url -Token $Token
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  [SKIP] Storage '$Name' not found (404)." -ForegroundColor DarkGray
            return
        }
        throw
    }
    $pna = $current.properties.publicNetworkAccess
    $defAction = $current.properties.networkAcls.defaultAction
    if ($pna -eq 'Enabled' -and $defAction -eq 'Allow') {
        Write-Host "  [OK] Storage '$Name' already reachable (Enabled / Allow)." -ForegroundColor DarkGray
        return
    }
    Write-Host "  [INFO] Storage '$Name' is pna='$pna' defaultAction='$defAction'. Re-enabling..." -ForegroundColor Yellow
    Invoke-Arm -Method PATCH -Url $url -Token $Token -Body @{ properties = @{ publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' } } } | Out-Null
    [void]$script:Flipped.Add("Storage $Name")
    Write-Host "  [OK] Storage '$Name' publicNetworkAccess=Enabled, defaultAction=Allow." -ForegroundColor Green
}

function Start-AdxIfStopped {
    param(
        [string]$Token,
        [string]$SubscriptionId,
        [string]$ClusterName
    )
    $rid = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Kusto/clusters/$ClusterName"
    $url = "https://management.azure.com${rid}?api-version=2023-08-15"
    try {
        $current = Invoke-Arm -Method GET -Url $url -Token $Token
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  [SKIP] ADX cluster '$ClusterName' not found (404)." -ForegroundColor DarkGray
            return
        }
        throw
    }
    $state = $current.properties.state
    if ($state -eq 'Running') { Write-Host "  [OK] ADX cluster '$ClusterName' already Running." -ForegroundColor DarkGray; return $rid }
    if ($state -eq 'Stopped') {
        Write-Host "  [INFO] ADX cluster '$ClusterName' is Stopped. Issuing /start..." -ForegroundColor Yellow
        Invoke-Arm -Method POST -Url "https://management.azure.com${rid}/start?api-version=2023-08-15" -Token $Token | Out-Null
        [void]$script:Started.Add("ADX cluster $ClusterName")
        Write-Host "  [OK] /start issued (cluster will reach Running in ~5-10 min)." -ForegroundColor Green
        return $rid
    }
    Write-Host "  [INFO] ADX cluster '$ClusterName' is '$state' (no action)." -ForegroundColor DarkGray
    return $rid
}

# --- Main ---
Resolve-FromDefinitions
$token = Get-Token
$sub = Get-SubscriptionId
$baseId = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers"

Write-Host ""
Write-Host "ClaudIA daily reachability restore" -ForegroundColor Cyan
Write-Host "  Subscription:    $sub"
Write-Host "  Resource group:  $ResourceGroup"
Write-Host "  Mode:            $(if ($UseAutomationManagedIdentity) { 'Azure Automation Managed Identity' } else { 'az CLI (local)' })"
Write-Host ""

if ($KeyVaultName) {
    Enable-Pna -Token $token -ResourceId "$baseId/Microsoft.KeyVault/vaults/$KeyVaultName" -ApiVersion '2023-07-01' -ResourceTypeLabel 'Key Vault' -Name $KeyVaultName
}
if ($OpenAiAccountName) {
    Enable-Pna -Token $token -ResourceId "$baseId/Microsoft.CognitiveServices/accounts/$OpenAiAccountName" -ApiVersion '2024-10-01' -ResourceTypeLabel 'Azure OpenAI' -Name $OpenAiAccountName
}
if ($AutomationAccountName) {
    Enable-Pna -Token $token -ResourceId "$baseId/Microsoft.Automation/automationAccounts/$AutomationAccountName" -ApiVersion '2023-11-01' -ResourceTypeLabel 'Automation' -Name $AutomationAccountName
}
if ($AdxClusterName) {
    $adxId = Start-AdxIfStopped -Token $token -SubscriptionId $sub -ClusterName $AdxClusterName
    if ($adxId) {
        Enable-Pna -Token $token -ResourceId $adxId -ApiVersion '2023-08-15' -ResourceTypeLabel 'ADX cluster' -Name $AdxClusterName
    }
}
if (-not $SkipStorage) {
    $storageNames = if ($StorageAccountNames) { $StorageAccountNames } else { Get-StorageAccountNamesInRg -Token $token -SubscriptionId $sub }
    foreach ($stName in $storageNames) {
        Enable-StoragePna -Token $token -SubscriptionId $sub -Name $stName
    }
}

Write-Host ""
if ($script:Flipped.Count -eq 0 -and $script:Started.Count -eq 0) {
    Write-Host "  Nothing to do. All ClaudIA resources are reachable." -ForegroundColor Green
} else {
    Write-Host "  Restore summary" -ForegroundColor Cyan
    foreach ($r in $script:Flipped) { Write-Host "    - publicNetworkAccess flipped: $r" -ForegroundColor Yellow }
    foreach ($r in $script:Started) { Write-Host "    - start issued:                $r" -ForegroundColor Yellow }
}
Write-Host ""
