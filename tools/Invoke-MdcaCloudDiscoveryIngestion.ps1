<#PSScriptInfo

.VERSION 1.0.0

.GUID 58167d8e-77f1-43de-a90f-98e8c4550b23

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
Export ADX telemetry and upload it to Microsoft Defender for Cloud Apps Cloud Discovery

.RELEASENOTES
Initial version metadata for the MDCA Cloud Discovery ingestion wrapper.

#>
<#
.SYNOPSIS
    Export ADX telemetry and upload it to MDCA Cloud Discovery.
.DESCRIPTION
    Runs the ClaudIA ADX export and MDCA upload scripts as a single ingestion
    operation. Step 10 stores MDCA settings in Key Vault, so this script can run
    without passing portal URL or API token on the command line.
.EXAMPLE
    .\tools\Invoke-MdcaCloudDiscoveryIngestion.ps1
.EXAMPLE
    .\tools\Invoke-MdcaCloudDiscoveryIngestion.ps1 -SinceMinutes 720 -Top 500 -UploadAsSnapshot
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [int]$SinceMinutes = 1440,
    [int]$Top = 100,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\out\mdca-adx-pilot.cef'),
    [switch]$UploadAsSnapshot
)

$ErrorActionPreference = 'Stop'

Write-Host '=== ClaudIA MDCA Cloud Discovery Ingestion ===' -ForegroundColor Cyan
Write-Host "  Window: $SinceMinutes minute(s)"
Write-Host "  Top:    $Top row(s)"
Write-Host "  Output: $OutputPath"
Write-Host ''

& (Join-Path $PSScriptRoot 'Export-MdcaDiscoveryLogFromAdx.ps1') `
    -ConfigPath $ConfigPath `
    -SinceMinutes $SinceMinutes `
    -Top $Top `
    -OutputPath $OutputPath

$uploadArgs = @{
    Path = $OutputPath
    ConfigPath = $ConfigPath
}
if ($UploadAsSnapshot) { $uploadArgs.UploadAsSnapshot = $true }

& (Join-Path $PSScriptRoot 'Upload-MdcaCloudDiscoveryLog.ps1') @uploadArgs

Write-Host ''
Write-Host '[OK] MDCA Cloud Discovery ingestion submitted.' -ForegroundColor Green
