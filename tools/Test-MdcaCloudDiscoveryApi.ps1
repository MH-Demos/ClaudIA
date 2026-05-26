<#PSScriptInfo

.VERSION 1.0.0

.GUID 091adba0-1dd8-4454-b016-66dd315fa851

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
Validate Microsoft Defender for Cloud Apps Cloud Discovery API connectivity

.RELEASENOTES
Initial version metadata for Validate Microsoft Defender for Cloud Apps Cloud Discovery API connectivity.

#>
<#
.SYNOPSIS
    Validate Microsoft Defender for Cloud Apps Cloud Discovery API connectivity.
.DESCRIPTION
    Reads an MDCA portal URL and API token from a temporary JSON config file or
    environment variables, then calls a read-only Cloud Discovery endpoint.
.EXAMPLE
    .\tools\Test-MdcaCloudDiscoveryApi.ps1
.EXAMPLE
    .\tools\Test-MdcaCloudDiscoveryApi.ps1 -ConfigPath "$env:TEMP\mdca-cloud-discovery.local.json"
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:TEMP 'mdca-cloud-discovery.local.json'),
    [string]$PortalUrl = $env:MDCA_PORTAL_URL,
    [string]$Token = $env:MDCA_API_TOKEN,
    [switch]$ProbeUploadUrl
)

$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $PortalUrl -and $config.portalUrl) { $PortalUrl = [string]$config.portalUrl }
    if (-not $Token -and $config.token) { $Token = [string]$config.token }
}

if (-not $PortalUrl) {
    throw 'Missing MDCA portal URL. Set MDCA_PORTAL_URL or provide portalUrl in the config file.'
}

if (-not $Token) {
    throw 'Missing MDCA API token. Set MDCA_API_TOKEN or provide token in the config file.'
}

$baseUri = $PortalUrl.TrimEnd('/')
$headers = @{
    Authorization = "Token $Token"
    Accept = 'application/json'
}

function Invoke-MdcaGet {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $uri = "$baseUri$Path"
    Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
}

Write-Host '=== MDCA Cloud Discovery API Probe ===' -ForegroundColor Cyan
Write-Host "  Portal: $baseUri"
Write-Host "  Config: $ConfigPath"
Write-Host ''

try {
    $streams = Invoke-MdcaGet -Path '/api/discovery/streams/'
    Write-Host '[OK] /api/discovery/streams/ responded.' -ForegroundColor Green

    $items = @()
    if ($streams -is [System.Array]) {
        $items = $streams
    } elseif ($streams.data) {
        $items = @($streams.data)
    } elseif ($streams.PSObject.Properties.Name -contains 'streams') {
        $items = @($streams.streams)
    }

    Write-Host "  Streams returned: $($items.Count)"
    if ($items.Count -gt 0) {
        $items |
            Select-Object -First 10 |
            ConvertTo-Json -Depth 6
    } else {
        $streams | ConvertTo-Json -Depth 6
    }
} catch {
    $response = $_.Exception.Response
    if ($response -and $response.StatusCode) {
        $statusCode = [int]$response.StatusCode
        $statusDescription = $response.StatusDescription
        throw "MDCA request failed: HTTP $statusCode $statusDescription"
    }
    throw
}

if ($ProbeUploadUrl) {
    $fileName = "mdca-adx-pilot-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).csv"
    $encodedFileName = [uri]::EscapeDataString($fileName)
    $uploadProbe = Invoke-MdcaGet -Path "/api/v1/discovery/upload_url/?filename=$encodedFileName&source=GENERIC_CEF"
    Write-Host ''
    Write-Host '[OK] /api/v1/discovery/upload_url/ responded.' -ForegroundColor Green
    Write-Host "  Provider: $($uploadProbe.provider)"
    Write-Host '  Upload URL received and intentionally not printed.'
}



