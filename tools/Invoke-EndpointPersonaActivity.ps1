<#PSScriptInfo

.VERSION 1.0.0

.GUID e5390e18-412b-4314-84a5-8f9fa46478e6

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
Runs user-attributed endpoint activity from a Windows 365 Cloud PC

.RELEASENOTES
Initial version metadata for Runs user-attributed endpoint activity from a Windows 365 Cloud PC.

#>
<#
.SYNOPSIS
    Runs user-attributed endpoint activity from a Windows 365 Cloud PC.
.DESCRIPTION
    Execute this script inside the Cloud PC while signed in as the target lab user.
    It creates Office documents with synthetic sensitive data and performs local
    endpoint actions that Microsoft Purview Endpoint DLP can report in Activity Explorer
    when the device is onboarded and the user/device are in policy scope.

    This script is intentionally local-first. It does not use Graph to apply labels,
    because Graph label operations are service-attributed in Activity Explorer.
.EXAMPLE
    .\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma
.EXAMPLE
    .\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma -NetworkSharePath \\server\share\PurviewLab -OpenBrowserPasteTest
#>
[CmdletBinding()]
param(
    [string]$Persona = 'priya.sharma',
    [string]$Department = 'Data Science',
    [string]$NetworkSharePath = '',
    [switch]$CopyToOneDrive,
    [switch]$OpenBrowserPasteTest,
    [switch]$OpenManualPrintTest,
    [string]$BrowserPasteUrl = 'https://www.bing.com/search'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message, [string]$Status = 'INFO')
    $color = switch ($Status) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host ("  [{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Get-OneDriveBusinessPath {
    $candidates = @()
    $envCandidates = @($env:OneDriveCommercial, $env:OneDrive)
    foreach ($candidate in $envCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $candidates += $candidate }
    }
    $profile = [Environment]::GetFolderPath('UserProfile')
    if ($profile) {
        $candidates += Get-ChildItem -LiteralPath $profile -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'OneDrive -*' } |
            Select-Object -ExpandProperty FullName
    }
    $candidates | Select-Object -First 1
}

function New-WordDocument {
    param([string]$Path, [string]$Content)
    $word = $null
    $doc = $null
    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $doc = $word.Documents.Add()
        $selection = $word.Selection
        $selection.TypeText($Content)
        $doc.SaveAs([ref]$Path, [ref]16)
        return $true
    }
    catch {
        Write-Step "Word document creation failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if ($doc) { $doc.Close([ref]$false) | Out-Null }
        if ($word) { $word.Quit() | Out-Null }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function New-ExcelWorkbook {
    param([string]$Path, [object[]]$Rows)
    $excel = $null
    $workbook = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $workbook = $excel.Workbooks.Add()
        $sheet = $workbook.Worksheets.Item(1)
        $headers = @('Employee', 'SSN', 'RoutingNumber', 'AccountNumber', 'Project', 'Risk')
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $sheet.Cells.Item(1, $i + 1) = $headers[$i]
        }
        $rowIndex = 2
        foreach ($row in $Rows) {
            for ($i = 0; $i -lt $headers.Count; $i++) {
                $sheet.Cells.Item($rowIndex, $i + 1) = [string]$row[$headers[$i]]
            }
            $rowIndex++
        }
        $sheet.UsedRange.Columns.AutoFit() | Out-Null
        $workbook.SaveAs($Path, 51)
        return $true
    }
    catch {
        Write-Step "Excel workbook creation failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if ($workbook) { $workbook.Close($false) | Out-Null }
        if ($excel) { $excel.Quit() | Out-Null }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Copy-LabFile {
    param([string]$Source, [string]$DestinationFolder, [string]$ActivityName)
    if (-not $DestinationFolder) { return $false }
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
    }
    $destination = Join-Path $DestinationFolder (Split-Path $Source -Leaf)
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    Write-Step "$ActivityName`: $destination" 'OK'
    return $true
}

Write-Host "=== Endpoint Persona Activity ===" -ForegroundColor Cyan
Write-Host "  Persona:    $Persona"
Write-Host "  User:       $env:USERNAME"
Write-Host "  Computer:   $env:COMPUTERNAME"
Write-Host "  Department: $Department"
Write-Host ""

$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
if ($sense) {
    Write-Step "Microsoft Defender for Endpoint Sense service: $($sense.Status)" ($(if ($sense.Status -eq 'Running') { 'OK' } else { 'WARN' }))
} else {
    Write-Step "Sense service not found. Verify Purview/MDE onboarding before expecting Endpoint DLP events." 'WARN'
}

$root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PurviewEndpointPersona\$Persona"
$stage = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -Path $stage -ItemType Directory -Force | Out-Null
Write-Step "Working folder: $stage" 'OK'

$sensitiveNarrative = @"
Confidential analytics note
Persona: $Persona
Department: $Department
Scenario: Priya correlates HR and sales extracts while troubleshooting access boundaries.

Synthetic sensitive data for lab use only:
- Employee: Jordan Avery
- SSN: 384-29-5187
- Routing number: 021000021
- Account number: 492017388201
- Customer contact: Morgan Lee, morgan.lee@example.com, +1 206 555 0174

Risk note:
This document intentionally combines HR identifiers, banking data, and customer escalation context
to trigger Purview Endpoint DLP and Activity Explorer events in a lab tenant.
"@

$docxPath = Join-Path $stage "Priya_HR_Sales_Correlation_$(Get-Date -Format 'yyyyMMdd_HHmmss').docx"
$xlsxPath = Join-Path $stage "Priya_Model_Feature_Extract_$(Get-Date -Format 'yyyyMMdd_HHmmss').xlsx"
$txtPath = Join-Path $stage "Priya_Clipboard_Source_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

if (New-WordDocument -Path $docxPath -Content $sensitiveNarrative) {
    Write-Step "Created DOCX: $docxPath" 'OK'
} else {
    $txtFallback = [System.IO.Path]::ChangeExtension($docxPath, '.txt')
    Set-Content -LiteralPath $txtFallback -Value $sensitiveNarrative -Encoding UTF8
    $docxPath = $txtFallback
    Write-Step "Created text fallback: $docxPath" 'WARN'
}

$rows = @(
    @{ Employee = 'Jordan Avery'; SSN = '384-29-5187'; RoutingNumber = '021000021'; AccountNumber = '492017388201'; Project = 'Customer churn model'; Risk = 'PII in feature set' },
    @{ Employee = 'Taylor Morgan'; SSN = '219-64-8821'; RoutingNumber = '026009593'; AccountNumber = '903441802991'; Project = 'Compensation analysis'; Risk = 'Banking data in dataset' }
)
if (New-ExcelWorkbook -Path $xlsxPath -Rows $rows) {
    Write-Step "Created XLSX: $xlsxPath" 'OK'
} else {
    $csvFallback = [System.IO.Path]::ChangeExtension($xlsxPath, '.csv')
    $rows | ForEach-Object { [pscustomobject]$_ } | Export-Csv -LiteralPath $csvFallback -NoTypeInformation -Encoding UTF8
    $xlsxPath = $csvFallback
    Write-Step "Created CSV fallback: $xlsxPath" 'WARN'
}

Set-Content -LiteralPath $txtPath -Value $sensitiveNarrative -Encoding UTF8
Write-Step "Created clipboard source: $txtPath" 'OK'

Set-Clipboard -Value $sensitiveNarrative
Write-Step "Copied sensitive text to clipboard" 'OK'

$oneDrivePath = Get-OneDriveBusinessPath
if ($CopyToOneDrive) {
    if ($oneDrivePath) {
        $target = Join-Path $oneDrivePath "Purview Endpoint Persona\$Persona"
        Copy-LabFile -Source $docxPath -DestinationFolder $target -ActivityName 'Copied DOCX to OneDrive sync folder' | Out-Null
        Copy-LabFile -Source $xlsxPath -DestinationFolder $target -ActivityName 'Copied XLSX to OneDrive sync folder' | Out-Null
    } else {
        Write-Step "OneDrive business path not found. Sign in/sync OneDrive first or omit -CopyToOneDrive." 'WARN'
    }
}

if ($NetworkSharePath) {
    try {
        $target = Join-Path $NetworkSharePath $Persona
        Copy-LabFile -Source $docxPath -DestinationFolder $target -ActivityName 'Copied DOCX to network share' | Out-Null
        Copy-LabFile -Source $xlsxPath -DestinationFolder $target -ActivityName 'Copied XLSX to network share' | Out-Null
    }
    catch {
        Write-Step "Network share copy failed: $($_.Exception.Message)" 'WARN'
    }
}

if ($OpenBrowserPasteTest) {
    Write-Step "Opening browser paste target. Paste the clipboard content into a text field to test browser paste monitoring." 'INFO'
    Start-Process $BrowserPasteUrl
}

if ($OpenManualPrintTest) {
    Write-Step "Opening DOCX. Use Word > Print > Microsoft Print to PDF to test FilePrinted." 'INFO'
    Start-Process $docxPath
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
[pscustomobject]@{
    Persona = $Persona
    Computer = $env:COMPUTERNAME
    User = $env:USERNAME
    WorkingFolder = $stage
    Docx = $docxPath
    Xlsx = $xlsxPath
    Clipboard = 'Sensitive text copied'
    OneDrivePath = $oneDrivePath
    NetworkSharePath = $NetworkSharePath
} | Format-List

Write-Host "Wait 10-30 minutes, then filter Activity Explorer by user, device, and activity type." -ForegroundColor Yellow



