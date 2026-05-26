<#PSScriptInfo

.VERSION 1.0.0

.GUID 617a2e17-c74b-495b-bac3-4fb541839ce3

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
Uploads ClaudIA persona images to Microsoft Entra user profile photos

.RELEASENOTES
Initial version metadata for Uploads ClaudIA persona images to Microsoft Entra user profile photos.

#>
<#
.SYNOPSIS
    Uploads ClaudIA persona images to Microsoft Entra user profile photos.
.DESCRIPTION
    Maps each agent in config\agents.json to an image in Images\Characters by
    displayName. The Microsoft 365 admin Azure CLI profile is used when present,
    otherwise the current Azure CLI session is used to get a Microsoft Graph
    token, unless CLAUDIA_GRAPH_TOKEN is already set by the installer. Use
    -WhatIf to validate mappings before uploading.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$ImagesPath = (Join-Path $PSScriptRoot '..\Images\Characters'),
    [string]$M365AzureConfigDir = $env:CLAUDIA_M365_AZURE_CONFIG_DIR,
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

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$AzureConfigDir
    )

    $oldConfigDir = $env:AZURE_CONFIG_DIR
    try {
        if ($AzureConfigDir) { $env:AZURE_CONFIG_DIR = $AzureConfigDir }
        $output = & az @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $output
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

function Get-GraphAccessToken {
    param([string]$AzureConfigDir)

    if ($env:CLAUDIA_GRAPH_TOKEN) {
        return @{
            Token = $env:CLAUDIA_GRAPH_TOKEN
            Source = 'CLAUDIA_GRAPH_TOKEN'
            Account = 'installer-provided'
        }
    }

    $profile = if ($AzureConfigDir -and (Test-Path -LiteralPath $AzureConfigDir)) {
        $AzureConfigDir
    } else {
        $candidate = Join-Path (Split-Path -Parent $PSScriptRoot) '.claudia\az-m365-admin'
        if (Test-Path -LiteralPath $candidate) { $candidate } else { $null }
    }

    $account = $null
    if ($profile) {
        $accountJson = Invoke-AzCli -AzureConfigDir $profile -Arguments @('account', 'show', '-o', 'json')
        if ($accountJson) {
            $accountInfo = $accountJson | ConvertFrom-Json
            $account = [string]$accountInfo.user.name
        }
        $token = Invoke-AzCli -AzureConfigDir $profile -Arguments @('account', 'get-access-token', '--resource-type', 'ms-graph', '--query', 'accessToken', '-o', 'tsv')
        if ($token) {
            return @{
                Token = [string]$token
                Source = $profile
                Account = $account
            }
        }
    }

    $accountJson = Invoke-AzCli -Arguments @('account', 'show', '-o', 'json')
    if ($accountJson) {
        $accountInfo = $accountJson | ConvertFrom-Json
        $account = [string]$accountInfo.user.name
    }
    $token = Invoke-AzCli -Arguments @('account', 'get-access-token', '--resource-type', 'ms-graph', '--query', 'accessToken', '-o', 'tsv')
    if ($token) {
        return @{
            Token = [string]$token
            Source = 'current Azure CLI profile'
            Account = $account
        }
    }

    return $null
}

function Get-GraphErrorMessage {
    param([Parameter(Mandatory)]$ErrorRecord)

    $responseText = $null
    try {
        $stream = $ErrorRecord.Exception.Response.GetResponseStream()
        if ($stream) {
            $reader = [IO.StreamReader]::new($stream)
            $responseText = $reader.ReadToEnd()
        }
    } catch {}

    if (-not $responseText -and $ErrorRecord.ErrorDetails.Message) {
        $responseText = $ErrorRecord.ErrorDetails.Message
    }

    if ($responseText) {
        try {
            $payload = $responseText | ConvertFrom-Json
            if ($payload.error.message) { return "$($payload.error.code): $($payload.error.message)" }
        } catch {}
        return $responseText
    }

    return $ErrorRecord.Exception.Message
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
$tokenSource = $null
if (-not $WhatIfPreference) {
    $tokenInfo = Get-GraphAccessToken -AzureConfigDir $M365AzureConfigDir
    if (-not $tokenInfo -or -not $tokenInfo.Token) {
        throw 'Could not acquire Microsoft Graph token. Run az login first, or rerun Install-ClaudIA.ps1 and use the separate Microsoft 365/Entra admin sign-in prompt.'
    }
    $token = $tokenInfo.Token
    $tokenSource = $tokenInfo.Source
    if ($tokenInfo.Account) {
        Write-Host "Using Microsoft Graph token from $tokenSource ($($tokenInfo.Account))." -ForegroundColor DarkGray
    } else {
        Write-Host "Using Microsoft Graph token from $tokenSource." -ForegroundColor DarkGray
    }
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
        try {
            Invoke-RestMethod `
                -Method PUT `
                -Uri $target `
                -Headers @{ Authorization = "Bearer $token" } `
                -ContentType (Get-ContentType -Path $imagePath) `
                -InFile $imagePath | Out-Null
        } catch {
            $graphError = Get-GraphErrorMessage -ErrorRecord $_
            throw @"
Could not upload the profile photo for $displayName <$upn>.
Graph returned: $graphError

Fix:
  - Sign in with a Microsoft 365/Entra admin account that can update user photos.
  - If Azure and Microsoft 365 use different admins, rerun Install-ClaudIA.ps1 and answer yes when it asks for a separate Microsoft 365/Entra admin sign-in.
  - Then retry: .\tools\Set-EntraUserPhotos.ps1 -SkipMissing

Token source used: $tokenSource
"@
        }
        $uploaded++
        Write-Host "Uploaded photo for $displayName <$upn>" -ForegroundColor Green
    } else {
        Write-Host "Mapped $displayName <$upn> -> $imagePath" -ForegroundColor Cyan
    }
}

Write-Host "Photo upload complete. Uploaded: $uploaded. Missing: $missing." -ForegroundColor Green



