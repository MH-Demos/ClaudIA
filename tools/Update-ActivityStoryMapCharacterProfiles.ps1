<#PSScriptInfo

.VERSION 1.0.0

.GUID 284c4f4a-cb9b-4f46-bac0-815747632407

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
Builds the Activity Story Map character profile manifest

.RELEASENOTES
Initial version metadata for Builds the Activity Story Map character profile manifest.

#>
<#
.SYNOPSIS
    Builds the Activity Story Map character profile manifest.
.DESCRIPTION
    Parses Storyline\characters_presentations.md and enriches matching users
    with Microsoft Entra manager/direct report relationships through Microsoft
    Graph. The generated JSON is published with the static web portal.
#>
param(
    [string]$StorylinePath = (Join-Path $PSScriptRoot '..\Storyline\characters_presentations.md'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\activity-story-map\web\character-profiles.json'),
    [switch]$SkipGraph
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ProfileKey {
    param([Parameter(Mandatory)][string]$Value)
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    return ($builder.ToString().ToLowerInvariant() -replace '@.*$', '' -replace '[^a-z0-9]+', '.' -replace '^\.+|\.+$', '')
}

function Convert-MarkdownInline {
    param([string]$Value)
    return ($Value -replace '^\s+|\s+$', '' -replace '^["“]|["”]$', '')
}

function Convert-SectionBody {
    param([string[]]$Lines)
    $clean = @($Lines | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' -and $_ -ne '---' })
    $items = @($clean | Where-Object { $_ -match '^- ' } | ForEach-Object { ($_ -replace '^- ', '').Trim() })
    if ($items.Count -gt 0 -and $items.Count -eq $clean.Count) { return $items }
    return (Convert-MarkdownInline (($clean -join "`n") -replace "`n", ' '))
}

function Invoke-GraphJson {
    param([Parameter(Mandatory)][string]$Url)
    $response = & az rest --method GET --url $Url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $response) { return $null }
    return $response | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $StorylinePath)) {
    throw "Storyline file not found: $StorylinePath"
}

$markdown = Get-Content -LiteralPath $StorylinePath -Raw -Encoding utf8
$matches = [regex]::Matches($markdown, '(?ms)^# (?!ClaudIA)(.+?)\r?\n(.*?)(?=^# (?!ClaudIA)|\z)')
$profiles = @()

foreach ($match in $matches) {
    $name = $match.Groups[1].Value.Trim()
    $body = $match.Groups[2].Value.Trim()
    if (-not $name -or -not $body) { continue }

    $tagline = ''
    $taglineMatch = [regex]::Match($body, '(?m)^##\s+(.+)$')
    if ($taglineMatch.Success) { $tagline = Convert-MarkdownInline $taglineMatch.Groups[1].Value }

    $sections = [ordered]@{}
    $sectionMatches = [regex]::Matches($body, '(?ms)^### (.+?)\r?\n(.*?)(?=^### |\z)')
    foreach ($sectionMatch in $sectionMatches) {
        $sectionName = $sectionMatch.Groups[1].Value.Trim()
        $lines = @($sectionMatch.Groups[2].Value -split '\r?\n')
        if ($sectionName -eq 'Basic Information') {
            $basic = [ordered]@{}
            $highlights = @()
            foreach ($line in $lines) {
                if ($line -match '^- \*\*(.+?):\*\*\s*(.+)$') {
                    $basic[$matches[1]] = $matches[2].Trim()
                } elseif ($line -match '^- \*\*(.+?)\*\*\s*$') {
                    $highlights += $matches[1].Trim()
                }
            }
            if ($highlights.Count -gt 0) { $basic['Highlights'] = $highlights }
            $sections[$sectionName] = $basic
        } else {
            $sections[$sectionName] = Convert-SectionBody -Lines $lines
        }
    }

    $basicInfo = $sections['Basic Information']
    $upn = if ($basicInfo -and $basicInfo['UPN']) { [string]$basicInfo['UPN'] } else { "$(ConvertTo-ProfileKey $name)@contoso.example" }
    $profile = [ordered]@{
        id = "agent:$(ConvertTo-ProfileKey $upn)"
        key = ConvertTo-ProfileKey $upn
        displayName = $name
        tagline = $tagline
        upn = $upn
        role = if ($basicInfo) { [string]$basicInfo['Role'] } else { '' }
        department = if ($basicInfo) { [string]$basicInfo['Department'] } else { '' }
        location = if ($basicInfo) { [string]$basicInfo['Location'] } else { '' }
        licenses = if ($basicInfo) { [string]$basicInfo['Licenses'] } else { '' }
        highlights = if ($basicInfo -and $basicInfo['Highlights']) { @($basicInfo['Highlights']) } else { @() }
        introduction = [string]$sections['Introduction']
        personality = @($sections['Personality'])
        dailyActivities = @($sections['Daily Activities'])
        technologies = @($sections['Technologies Frequently Used'])
        sensitiveDataExposure = @($sections['Sensitive Data Exposure'])
        areasOfExpertise = @($sections['Areas of Expertise'])
        communityLeadership = @($sections['Community & Leadership'])
        personalMotto = [string]$sections['Personal Motto']
        demoFocus = @($sections['Demo Focus'])
        entra = [ordered]@{
            exists = $false
            manager = $null
            directReports = @()
        }
    }

    if (-not $SkipGraph) {
        $escapedUpn = [System.Uri]::EscapeDataString($upn)
        $user = Invoke-GraphJson -Url "https://graph.microsoft.com/v1.0/users/$escapedUpn`?`$select=id,displayName,userPrincipalName,jobTitle,department"
        if ($user) {
            $profile.entra.exists = $true
            $profile.entra.displayName = [string]$user.displayName
            $profile.entra.jobTitle = [string]$user.jobTitle
            $profile.entra.department = [string]$user.department

            $manager = Invoke-GraphJson -Url "https://graph.microsoft.com/v1.0/users/$escapedUpn/manager?`$select=id,displayName,userPrincipalName,jobTitle,department"
            if ($manager) {
                $profile.entra.manager = [ordered]@{
                    id = "agent:$(ConvertTo-ProfileKey ([string]$manager.userPrincipalName))"
                    displayName = [string]$manager.displayName
                    upn = [string]$manager.userPrincipalName
                    jobTitle = [string]$manager.jobTitle
                    department = [string]$manager.department
                }
            }

            $reports = Invoke-GraphJson -Url "https://graph.microsoft.com/v1.0/users/$escapedUpn/directReports?`$select=id,displayName,userPrincipalName,jobTitle,department"
            if ($reports -and $reports.value) {
                $profile.entra.directReports = @($reports.value | Where-Object { $_.userPrincipalName } | ForEach-Object {
                    [ordered]@{
                        id = "agent:$(ConvertTo-ProfileKey ([string]$_.userPrincipalName))"
                        displayName = [string]$_.displayName
                        upn = [string]$_.userPrincipalName
                        jobTitle = [string]$_.jobTitle
                        department = [string]$_.department
                    }
                })
            }
        }
    }

    $profiles += [PSCustomObject]$profile
}

$manifest = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    source = (Resolve-Path -LiteralPath $StorylinePath).Path
    profiles = $profiles
}

$outputDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Generated character profile manifest: $OutputPath" -ForegroundColor Green
Write-Host "Profiles: $($profiles.Count)"



