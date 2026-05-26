<#PSScriptInfo

.VERSION 1.0.1
.GUID 72c65792-91bf-4113-85ee-ec9b60c7d0df

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Microsoft365 Azure Purview MDCA

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Configure Microsoft Defender for Cloud Apps Cloud Discovery upload settings for ClaudIA

.RELEASENOTES
Version 1.0.1 recommends the single-step MDCA ingestion wrapper after connector setup.

#>
<#
.SYNOPSIS
    Configure Microsoft Defender for Cloud Apps Cloud Discovery upload settings.
.DESCRIPTION
    Stores the MDCA portal URL and API token in Azure Key Vault, records
    non-secret connector settings in config/agents.json, and validates the MDCA
    Cloud Discovery API. Use Export-MdcaDiscoveryLogFromAdx.ps1 and
    Upload-MdcaCloudDiscoveryLog.ps1 for the upload flow.
.EXAMPLE
    .\tools\Deploy-MdcaCloudDiscoveryConnector.ps1 -PortalUrl https://contoso.portal.cloudappsecurity.com -Token '<token>' -ProbeUploadUrl
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [Parameter(Mandatory)][string]$PortalUrl,
    [Parameter(Mandatory)][string]$Token,
    [string]$InputStreamName = 'ClaudIA ADX Cloud Discovery',
    [string]$PortalUrlSecretName = 'mdca-portal-url',
    [string]$TokenSecretName = 'mdca-api-token',
    [switch]$ProbeUploadUrl
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
$kvName = Get-KeyVaultName -Config $config
if (-not $kvName) { throw 'Key Vault name could not be resolved from configuration.' }
if ($config.tenant.subscriptionId) { az account set -s $config.tenant.subscriptionId 2>$null }

Write-Host '=== Deploy MDCA Cloud Discovery Connector ===' -ForegroundColor Cyan
Write-Host "  Key Vault: $kvName"
Write-Host "  Portal:    $($PortalUrl.TrimEnd('/'))"
Write-Host "  Stream:    $InputStreamName"
Write-Host ''

az keyvault secret set --vault-name $kvName --name $PortalUrlSecretName --value $PortalUrl.TrimEnd('/') -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not store Key Vault secret '$PortalUrlSecretName'." }
az keyvault secret set --vault-name $kvName --name $TokenSecretName --value $Token -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not store Key Vault secret '$TokenSecretName'." }

if (-not $config.PSObject.Properties['mdca']) {
    $config | Add-Member -NotePropertyName mdca -NotePropertyValue ([pscustomobject]@{}) -Force
}
Set-AAObjectProperty -Object $config.mdca -Name enabled -Value $true
Set-AAObjectProperty -Object $config.mdca -Name portalUrlSecretName -Value $PortalUrlSecretName
Set-AAObjectProperty -Object $config.mdca -Name tokenSecretName -Value $TokenSecretName
Set-AAObjectProperty -Object $config.mdca -Name keyVaultName -Value $kvName
Set-AAObjectProperty -Object $config.mdca -Name inputStreamName -Value $InputStreamName
Set-AAObjectProperty -Object $config.mdca -Name source -Value 'GENERIC_CEF'
Set-AAObjectProperty -Object $config.mdca -Name sinceMinutes -Value 1440
$config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8

& (Join-Path $PSScriptRoot 'Test-MdcaCloudDiscoveryApi.ps1') -PortalUrl $PortalUrl -Token $Token -ProbeUploadUrl:$ProbeUploadUrl

Write-Host ''
Write-Host '[OK] MDCA connector settings saved.' -ForegroundColor Green
Write-Host 'Run an ADX to MDCA ingestion with:' -ForegroundColor Yellow
Write-Host '  .\tools\Invoke-MdcaCloudDiscoveryIngestion.ps1' -ForegroundColor White
