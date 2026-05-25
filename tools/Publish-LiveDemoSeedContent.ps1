<#
.SYNOPSIS
    Uploads the 2026-05-27 live demo seed content pack to a SharePoint document library.
.DESCRIPTION
    Uses the current Azure CLI Microsoft Graph token to upload synthetic Defender/Purview
    demo documents from content-library/live-demo into a SharePoint drive.

    The files are synthetic lab data. Upload them several days before the live demo so
    Microsoft Search, Copilot, and Purview classification have time to index them.
.EXAMPLE
    .\tools\Publish-LiveDemoSeedContent.ps1 -SiteId "contoso.sharepoint.com,guid1,guid2"
.EXAMPLE
    .\tools\Publish-LiveDemoSeedContent.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/Demo"
.EXAMPLE
    .\tools\Publish-LiveDemoSeedContent.ps1 -Hostname "contoso.sharepoint.com" -SitePath "/sites/Demo"
.EXAMPLE
    .\tools\Publish-LiveDemoSeedContent.ps1 -SiteId "contoso.sharepoint.com,guid1,guid2" -RootFolder "LiveDemo/Purview"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteUrl = "",

    [string]$SiteId,

    [string]$Hostname = "",

    [string]$SitePath = "",

    [string]$RootFolder = "LiveDemo/Purview-Defender-2026-05-27",

    [string]$ContentRoot = (Join-Path $PSScriptRoot "..\content-library\live-demo")
)

$ErrorActionPreference = "Stop"

function Invoke-GraphJson {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$ContentType = "application/json"
    )

    $headers = @{ Authorization = "Bearer $Token" }
    if ($Body -ne $null) {
        if ($Body -is [byte[]]) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $Body -ContentType $ContentType
        }
        $json = $Body | ConvertTo-Json -Depth 12
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType $ContentType
    }

    Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

if (-not (Test-Path -LiteralPath $ContentRoot)) {
    throw "ContentRoot not found: $ContentRoot"
}

$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
    throw "Azure CLI is required. Run az login first, then re-run this script."
}

$token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>$null
if (-not $token) {
    throw "Could not acquire Microsoft Graph token from Azure CLI. Run az login first."
}

if (-not $SiteId -and $SiteUrl) {
    $uri = [System.Uri]$SiteUrl
    $Hostname = $uri.Host
    $SitePath = $uri.AbsolutePath.TrimEnd("/")
}

if (-not $SiteId -and $Hostname -and $SitePath) {
    $normalizedPath = if ($SitePath.StartsWith("/")) { $SitePath } else { "/$SitePath" }
    $lookupPath = (($normalizedPath.Trim('/') -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $site = Invoke-GraphJson -Token $token -Uri "https://graph.microsoft.com/v1.0/sites/$Hostname`:/$lookupPath"
    $SiteId = $site.id
    if (-not $SiteId) {
        throw "Could not resolve SharePoint site from Hostname '$Hostname' and SitePath '$SitePath'."
    }
    Write-Host "Resolved site: $($site.webUrl)" -ForegroundColor Cyan
}

if (-not $SiteId) {
    throw "Provide -SiteUrl, or -Hostname with -SitePath, or a real -SiteId in the format hostname,siteCollectionId,webId."
}

if ($SiteId -match "guid1|guid2") {
    throw "The SiteId value still contains placeholder text. Use -SiteUrl 'https://contoso.sharepoint.com/sites/<site-name>' or provide the real Graph site id."
}

$drive = Invoke-GraphJson -Token $token -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive"
if (-not $drive.id) {
    throw "Could not resolve default drive for site $SiteId"
}

$files = Get-ChildItem -LiteralPath $ContentRoot -Recurse -File |
    Where-Object { $_.Name -ne "README.md" } |
    Sort-Object FullName

Write-Host "Uploading $($files.Count) live demo seed files to SharePoint drive '$($drive.name)'." -ForegroundColor Cyan
Write-Host "Target folder: $RootFolder" -ForegroundColor Gray

$uploaded = @()
$contentRootFull = [System.IO.Path]::GetFullPath($ContentRoot).TrimEnd("\", "/")
foreach ($file in $files) {
    $fileFull = [System.IO.Path]::GetFullPath($file.FullName)
    $relative = $fileFull.Substring($contentRootFull.Length).TrimStart("\", "/").Replace("\", "/")
    $targetPath = "$RootFolder/$relative"
    $encodedPath = ($targetPath -split "/" | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join "/"
    $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$encodedPath`:/content"
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    if ($PSCmdlet.ShouldProcess($targetPath, "Upload seed document")) {
        $result = Invoke-GraphJson -Token $token -Method "PUT" -Uri $uri -Body $bytes -ContentType "application/octet-stream"
        $uploaded += [pscustomobject]@{
            Name = $result.name
            WebUrl = $result.webUrl
            Size = $result.size
        }
        Write-Host "  [OK] $targetPath" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Uploaded $($uploaded.Count) files." -ForegroundColor Cyan
$uploaded | Format-Table -AutoSize
