<#PSScriptInfo

.VERSION 1.0.0

.GUID d0f85a7b-3fa0-4714-ad08-c7def8e48841

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
Test Public Repo Safety script

.RELEASENOTES
Initial version metadata for Test Public Repo Safety script.

#>
param(
    [string]$Path = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path -LiteralPath $Path
$issues = New-Object System.Collections.Generic.List[string]

$blockedPaths = @(
    'BrowserAgents\.auth',
    'BrowserAgents\node_modules',
    'BrowserAgents\playwright-report',
    'BrowserAgents\test-results',
    'TeamsBot\node_modules',
    'TeamsBot\logs',
    'logs',
    'out'
)

foreach ($relative in $blockedPaths) {
    $candidate = Join-Path $root.Path $relative
    if (Test-Path -LiteralPath $candidate) {
        $issues.Add("Blocked generated/local path exists: $relative")
    }
}

$blockedFilePatterns = @(
    '.env',
    '*.log',
    'temp_*.json',
    'TeamsBot\config\claudia.runtime.json',
    'expansion-packs\claudia-teams-bot\config\agents.json',
    'expansion-packs\claudia-teams-bot\config\Installation_definitions.json'
)

foreach ($pattern in $blockedFilePatterns) {
    if ($pattern -like '*\*') {
        $candidate = Join-Path $root.Path $pattern
        if (Test-Path -LiteralPath $candidate) {
            $issues.Add("Blocked local file exists: $pattern")
        }
    } else {
        Get-ChildItem -LiteralPath $root.Path -Recurse -Force -File -Filter $pattern |
            Where-Object { $_.FullName -notmatch '\\.git\\' } |
            ForEach-Object { $issues.Add("Blocked local file exists: $($_.FullName.Substring($root.Path.Length + 1))") }
    }
}

$secretPatterns = [ordered]@{
    'Known lab domain' = 'mhdemos\.com'
    'Known tenant id' = 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4'
    'Known subscription id' = 'e0435491-8148-4b92-b004-c4525008aa47'
    'Known app id' = '6cf7ccdb-4b8f-4fc0-adaf-082e9175aeb8'
    'Known function identity id' = 'dcac935e-efb5-4bc5-ba56-07fb76ef4e34'
    'Known validation token' = '_iaf[0-9a-z]+'
    'Private key marker' = '-----BEGIN (RSA |OPENSSH |EC |)PRIVATE KEY-----'
    'Client secret assignment' = '(client_secret|clientSecret|ClientSecret)\s*[:=]\s*["''][^<"''][^"'']{11,}'
    'Password assignment' = '(password|passwd|AgentPassword)\s*[:=]\s*["''][^<"''][^"'']{7,}'
    'Connection string' = '(AccountKey=|SharedAccessKey=|DefaultEndpointsProtocol=)'
    'Bearer token' = 'Bearer\s+[A-Za-z0-9._-]{20,}'
}

$allowedPublicReferences = @(
    'https://activitymap.mhdemos.com',
    'activitymap.mhdemos.com'
)

$textFiles = Get-ChildItem -LiteralPath $root.Path -Recurse -Force -File |
    Where-Object {
        $_.FullName -notmatch '\\.git\\' -and
        $_.FullName -ne $PSCommandPath -and
        $_.FullName -notmatch '\\Images\\' -and
        $_.Extension -notin @('.png', '.jpg', '.jpeg', '.ico', '.zip')
    }

foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { continue }
    foreach ($allowed in $allowedPublicReferences) {
        $content = $content.Replace($allowed, '')
    }

    foreach ($name in $secretPatterns.Keys) {
        if ($content -match $secretPatterns[$name]) {
            $relative = $file.FullName.Substring($root.Path.Length + 1)
            $issues.Add("$name pattern found in $relative")
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host "Public repository safety check failed:" -ForegroundColor Red
    $issues | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 1
}

Write-Host "Public repository safety check passed." -ForegroundColor Green



