<#PSScriptInfo

.VERSION 1.0.0

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
Initial version metadata for Upload a Cloud Discovery log file to Microsoft Defender for Cloud Apps.

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

    [string]$ConfigPath = (Join-Path $env:TEMP 'mdca-cloud-discovery.local.json'),
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
    if (-not $PortalUrl -and $config.portalUrl) { $PortalUrl = [string]$config.portalUrl }
    if (-not $Token -and $config.token) { $Token = [string]$config.token }
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



