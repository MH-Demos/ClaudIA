<#
.SYNOPSIS
    Prepares and launches Microsoft Edge persona activity for Endpoint DLP testing.
.DESCRIPTION
    Run this script inside a Windows 365 Cloud PC while signed in as the lab user.
    It creates synthetic sensitive files, copies sensitive text to the clipboard,
    and opens Microsoft Edge with a selected profile and test URLs.

    Microsoft Edge is the preferred browser for this pilot because Purview Endpoint
    DLP browser/domain restrictions are natively integrated with Edge. Chrome and
    Firefox require the Microsoft Purview extension.

    The script does not use Graph to label files. Its purpose is to drive browser
    and endpoint actions that Activity Explorer can attribute to the signed-in
    Windows user and device.
.EXAMPLE
    .\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -UploadUrl https://copilot.microsoft.com
.EXAMPLE
    .\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -EdgeProfileDirectory "Profile 2" -PasteUrl https://chat.openai.com
.EXAMPLE
    .\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -UseIsolatedProfile -ProfileName Priya-Purview-Demo
#>
[CmdletBinding()]
param(
    [string]$Persona = 'priya.sharma',
    [string]$Department = 'Data Science',
    [string]$EdgeProfileDirectory = 'Default',
    [switch]$UseIsolatedProfile,
    [string]$ProfileName = '',
    [string]$UploadUrl = '',
    [string]$PasteUrl = '',
    [string]$PrintUrl = '',
    [string]$SaveAsUrl = '',
    [string]$NetworkSharePath = '',
    [switch]$OpenDownloadsFolder
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

function Get-EdgePath {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LocalAppData\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Microsoft Edge executable was not found."
}

function ConvertTo-HtmlEncodedText {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

Write-Host "=== Edge Persona Activity ===" -ForegroundColor Cyan
Write-Host "  Persona:    $Persona"
Write-Host "  User:       $env:USERNAME"
Write-Host "  Computer:   $env:COMPUTERNAME"
Write-Host "  Department: $Department"
Write-Host ""

$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
if ($sense) {
    Write-Step "Microsoft Defender for Endpoint Sense service: $($sense.Status)" ($(if ($sense.Status -eq 'Running') { 'OK' } else { 'WARN' }))
} else {
    Write-Step "Sense service not found. Endpoint DLP browser events may not appear." 'WARN'
}

$edgePath = Get-EdgePath
Write-Step "Edge path: $edgePath" 'OK'

$root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PurviewEdgePersona\$Persona"
$stage = Join-Path $root (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -Path $stage -ItemType Directory -Force | Out-Null
Write-Step "Working folder: $stage" 'OK'

$sensitiveText = @"
Priya Sharma endpoint browser test
Department: $Department
Scenario: Priya tests a model feature extract using sensitive HR and customer data.

Synthetic sensitive data for lab use only:
SSN: 384-29-5187
ABA routing number: 021000021
Bank account number: 492017388201
Customer: Morgan Lee, morgan.lee@example.com, +1 206 555 0174
Project: Copilot-driven HR and sales correlation
"@

$csvPath = Join-Path $stage "Priya_Browser_Upload_Test_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$txtPath = Join-Path $stage "Priya_Browser_Paste_Test_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$htmlPath = Join-Path $stage "Priya_Browser_Print_Save_Test_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

@(
    [pscustomobject]@{
        Employee = 'Jordan Avery'
        SSN = '384-29-5187'
        RoutingNumber = '021000021'
        AccountNumber = '492017388201'
        Customer = 'Morgan Lee'
        Project = 'Copilot-driven HR and sales correlation'
    },
    [pscustomobject]@{
        Employee = 'Taylor Morgan'
        SSN = '219-64-8821'
        RoutingNumber = '026009593'
        AccountNumber = '903441802991'
        Customer = 'Contoso Retail Services'
        Project = 'Executive churn-risk model'
    }
) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Set-Content -LiteralPath $txtPath -Value $sensitiveText -Encoding UTF8

$encoded = ConvertTo-HtmlEncodedText -Text $sensitiveText
$html = @"
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Priya Browser DLP Test</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 32px; line-height: 1.45; }
    textarea { width: 100%; min-height: 220px; font-family: Consolas, monospace; }
    .panel { border: 1px solid #ccc; padding: 16px; margin-bottom: 16px; }
  </style>
</head>
<body>
  <h1>Priya Browser DLP Test</h1>
  <div class="panel">
    <p>Paste test target. Use Ctrl+V here after the script loads the clipboard.</p>
    <textarea id="pasteTarget"></textarea>
  </div>
  <div class="panel">
    <p>Print / save-as test content.</p>
    <pre>$encoded</pre>
  </div>
</body>
</html>
"@
Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

Set-Clipboard -Value $sensitiveText
Write-Step "Created CSV upload file: $csvPath" 'OK'
Write-Step "Created text source file: $txtPath" 'OK'
Write-Step "Created local browser test page: $htmlPath" 'OK'
Write-Step "Copied sensitive text to clipboard" 'OK'

if ($NetworkSharePath) {
    try {
        $target = Join-Path $NetworkSharePath $Persona
        if (-not (Test-Path -LiteralPath $target)) { New-Item -Path $target -ItemType Directory -Force | Out-Null }
        Copy-Item -LiteralPath $csvPath -Destination (Join-Path $target (Split-Path $csvPath -Leaf)) -Force
        Copy-Item -LiteralPath $txtPath -Destination (Join-Path $target (Split-Path $txtPath -Leaf)) -Force
        Write-Step "Copied browser test files to network share: $target" 'OK'
    }
    catch {
        Write-Step "Network share copy failed: $($_.Exception.Message)" 'WARN'
    }
}

$urls = New-Object System.Collections.Generic.List[string]
$urls.Add((New-Object System.Uri($htmlPath)).AbsoluteUri)
if ($UploadUrl) { $urls.Add($UploadUrl) }
if ($PasteUrl) { $urls.Add($PasteUrl) }
if ($PrintUrl) { $urls.Add($PrintUrl) }
if ($SaveAsUrl) { $urls.Add($SaveAsUrl) }

$args = New-Object System.Collections.Generic.List[string]
if ($UseIsolatedProfile) {
    if (-not $ProfileName) { $ProfileName = "$Persona-EdgePersona" }
    $profileRoot = Join-Path $root "EdgeUserData\$ProfileName"
    New-Item -Path $profileRoot -ItemType Directory -Force | Out-Null
    $args.Add("--user-data-dir=$profileRoot")
    Write-Step "Using isolated Edge profile folder: $profileRoot" 'WARN'
    Write-Step "Sign into this Edge profile as the intended M365 user before trusting browser-user attribution." 'WARN'
} else {
    $args.Add("--profile-directory=$EdgeProfileDirectory")
    Write-Step "Using existing Edge profile directory: $EdgeProfileDirectory" 'OK'
}

$args.Add('--new-window')
foreach ($url in $urls) { $args.Add($url) }

Start-Process -FilePath $edgePath -ArgumentList $args
Write-Step "Edge launched with $($urls.Count) tab(s)." 'OK'

if ($OpenDownloadsFolder) {
    Start-Process (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
}

Write-Host ""
Write-Host "=== Manual browser actions to perform ===" -ForegroundColor Cyan
Write-Host "  1. In the local test page, press Ctrl+V in the textarea."
Write-Host "  2. On the configured upload site, upload this file:"
Write-Host "     $csvPath"
Write-Host "  3. From Edge, use Print > Microsoft Print to PDF on the test page or target site."
Write-Host "  4. Use Ctrl+S / Save page as on the test page or target site."
Write-Host ""
Write-Host "Wait 10-30 minutes, then filter Activity Explorer by Priya, the Cloud PC device, and browser/endpoint activities." -ForegroundColor Yellow
