<#PSScriptInfo

.VERSION 1.0.1

.GUID d931563d-3020-4f13-af14-6df6ee2a37a0

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
Upload a Cloud Discovery log file to Microsoft Defender for Cloud Apps

.RELEASENOTES
Version 1.0.1 reads MDCA portal URL and API token from ClaudIA Key Vault configuration when available.

#>
<#
.SYNOPSIS
    Upload a Cloud Discovery log file to Microsoft Defender for Cloud Apps.
.DESCRIPTION
    Uses the MDCA Cloud Discovery upload API sequence:
    initiate upload URL, PUT file content, finalize upload.
.EXAMPLE
    .\tools\Upload-MdcaCloudDiscoveryLog.ps1 -Path .\out\pilot.cef -InputStreamName 'ADX Synthetic Pilot' -UploadAsSnapshot
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$PortalUrl = $env:MDCA_PORTAL_URL,
    [string]$Token = $env:MDCA_API_TOKEN,
    [string]$Source = 'GENERIC_CEF',
    [string]$InputStreamName = 'ADX Synthetic MDCA Pilot',
    [switch]$UploadAsSnapshot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Log file not found: $Path"
}

if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($config.mdca) {
        if ($config.tenant.subscriptionId) { az account set -s $config.tenant.subscriptionId 2>$null }
        $kvName = [string]$config.mdca.keyVaultName
        if (-not $PortalUrl -and $kvName -and $config.mdca.portalUrlSecretName) {
            $PortalUrl = az keyvault secret show --vault-name $kvName --name $config.mdca.portalUrlSecretName --query value -o tsv 2>$null
        }
        if (-not $Token -and $kvName -and $config.mdca.tokenSecretName) {
            $Token = az keyvault secret show --vault-name $kvName --name $config.mdca.tokenSecretName --query value -o tsv 2>$null
        }
        if ($InputStreamName -eq 'ADX Synthetic MDCA Pilot' -and $config.mdca.inputStreamName) {
            $InputStreamName = [string]$config.mdca.inputStreamName
        }
        if ($Source -eq 'GENERIC_CEF' -and $config.mdca.source) {
            $Source = [string]$config.mdca.source
        }
    } else {
        if (-not $PortalUrl -and $config.portalUrl) { $PortalUrl = [string]$config.portalUrl }
        if (-not $Token -and $config.token) { $Token = [string]$config.token }
    }
}

if (-not $PortalUrl) { throw 'Missing MDCA portal URL.' }
if (-not $Token) { throw 'Missing MDCA API token.' }

$baseUri = $PortalUrl.TrimEnd('/')
$file = Get-Item -LiteralPath $Path
$encodedFileName = [uri]::EscapeDataString($file.Name)
$encodedSource = [uri]::EscapeDataString($Source)
$headers = @{
    Authorization = "Token $Token"
    Accept = 'application/json'
}

Write-Host '=== MDCA Cloud Discovery Upload ===' -ForegroundColor Cyan
Write-Host "  Portal: $baseUri"
Write-Host "  File:   $($file.FullName)"
Write-Host "  Source: $Source"
Write-Host "  Stream: $InputStreamName"
Write-Host "  Mode:   $(if ($UploadAsSnapshot) { 'Snapshot' } else { 'Continuous stream' })"
Write-Host ''

$initUri = "$baseUri/api/v1/discovery/upload_url/?filename=$encodedFileName&source=$encodedSource"
$uploadTarget = Invoke-RestMethod -Method GET -Uri $initUri -Headers $headers -ErrorAction Stop
if (-not $uploadTarget.url) {
    throw 'MDCA did not return an upload URL.'
}

$contentType = if ($file.Extension -match '\.gz$') { 'application/gzip' } else { 'text/plain' }
$putHeaders = @{}
if ($uploadTarget.provider -eq 'azure') {
    $putHeaders['x-ms-blob-type'] = 'BlockBlob'
}

Invoke-RestMethod -Method PUT `
    -Uri $uploadTarget.url `
    -InFile $file.FullName `
    -ContentType $contentType `
    -Headers $putHeaders `
    -ErrorAction Stop | Out-Null

$body = @{
    uploadUrl = $uploadTarget.url
    inputStreamName = $InputStreamName
}
if ($UploadAsSnapshot) {
    $body.uploadAsSnapshot = $true
}

$finalizeUri = "$baseUri/api/v1/discovery/done_upload/"
Invoke-RestMethod -Method POST `
    -Uri $finalizeUri `
    -Headers ($headers + @{ 'Content-Type' = 'application/json' }) `
    -Body ($body | ConvertTo-Json -Compress) `
    -ErrorAction Stop | Out-Null

Write-Host '[OK] Upload finalized. MDCA processing is asynchronous.' -ForegroundColor Green



