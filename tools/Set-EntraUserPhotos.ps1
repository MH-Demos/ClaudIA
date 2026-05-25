<#
.SYNOPSIS
    Uploads ClaudIA persona images to Microsoft Entra user profile photos.
.DESCRIPTION
    Maps each agent in config\agents.json to an image in Images\Characters by
    displayName. The current Azure CLI session is used to get a Microsoft Graph
    token, unless CLAUDIA_GRAPH_TOKEN is already set by the installer. Use
    -WhatIf to validate mappings before uploading.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$ImagesPath = (Join-Path $PSScriptRoot '..\Images\Characters'),
    [string[]]$Agent,
    [switch]$SkipMissing
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ImageKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    return ($builder.ToString().ToLowerInvariant() -replace '@.*$', '' -replace '[^a-z0-9]+', '' -replace '^\.+|\.+$', '')
}

function Get-ContentType {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.jpg' { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.png' { 'image/png' }
        default { throw "Unsupported image type: $Path" }
    }
}

function Get-AgentUpn {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][string]$Domain
    )

    if ($Agent.userPrincipalName) { return [string]$Agent.userPrincipalName }
    if ($Agent.upn) { return [string]$Agent.upn }
    if ("$($Agent.sam)" -match '@') { return [string]$Agent.sam }
    return "$($Agent.sam)@$Domain"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
if (-not (Test-Path -LiteralPath $ImagesPath)) { throw "Images folder not found: $ImagesPath" }

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$domain = [string]$config.tenant.domain
$agents = @($config.agents)
if ($Agent -and $Agent.Count -gt 0) {
    $wanted = @($Agent | ForEach-Object { ConvertTo-ImageKey $_ })
    $agents = @($agents | Where-Object {
        $wanted -contains (ConvertTo-ImageKey ([string]$_.sam)) -or
        $wanted -contains (ConvertTo-ImageKey ([string]$_.displayName)) -or
        $wanted -contains (ConvertTo-ImageKey ([string]$_.userPrincipalName))
    })
}

if ($agents.Count -eq 0) { throw 'No matching agents found.' }

$images = @{}
Get-ChildItem -LiteralPath $ImagesPath -File | Where-Object {
    $_.Extension.ToLowerInvariant() -in @('.png', '.jpg', '.jpeg')
} | ForEach-Object {
    $images[(ConvertTo-ImageKey $_.BaseName)] = $_.FullName
}

$token = $null
if (-not $WhatIfPreference) {
    $token = if ($env:CLAUDIA_GRAPH_TOKEN) {
        $env:CLAUDIA_GRAPH_TOKEN
    } else {
        az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>$null
    }
    if (-not $token) { throw 'Could not acquire Microsoft Graph token. Run az login first.' }
}

$uploaded = 0
$missing = 0

foreach ($agentInfo in $agents) {
    $displayName = [string]$agentInfo.displayName
    $upn = Get-AgentUpn -Agent $agentInfo -Domain $domain
    if (-not $displayName -or -not $upn) {
        Write-Warning 'Skipping agent with missing displayName or userPrincipalName.'
        continue
    }

    $key = ConvertTo-ImageKey $displayName
    $imagePath = $images[$key]
    if (-not $imagePath) {
        $missing++
        $message = "No image found for '$displayName'. Expected a file like '$displayName.png' in $ImagesPath."
        if ($SkipMissing) {
            Write-Warning $message
            continue
        }
        throw $message
    }

    $target = "https://graph.microsoft.com/v1.0/users/$([System.Uri]::EscapeDataString($upn))/photo/`$value"
    if ($PSCmdlet.ShouldProcess($upn, "Upload profile photo from $imagePath")) {
        Invoke-RestMethod `
            -Method PUT `
            -Uri $target `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType (Get-ContentType -Path $imagePath) `
            -InFile $imagePath | Out-Null
        $uploaded++
        Write-Host "Uploaded photo for $displayName <$upn>" -ForegroundColor Green
    } else {
        Write-Host "Mapped $displayName <$upn> -> $imagePath" -ForegroundColor Cyan
    }
}

Write-Host "Photo upload complete. Uploaded: $uploaded. Missing: $missing." -ForegroundColor Green
