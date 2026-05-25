<#
.SYNOPSIS
    Publishes Activity Story Map images to the existing static website storage.
.DESCRIPTION
    Copies images from Images\Characters, Images\Services, and Images\Branding into the Story Map
    web asset folder, generates a simple manifest, and uploads the web folder to
    the already configured Storage static website.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$ImagesRoot = (Join-Path $PSScriptRoot '..\Images'),
    [switch]$PurgeFrontDoor
)

$ErrorActionPreference = 'Stop'

function ConvertTo-AssetKey {
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

function ConvertTo-WebPath {
    param([Parameter(Mandatory)][string]$RelativePath)
    return './' + ($RelativePath -replace '\\', '/' -replace ' ', '%20' -replace 'í', '%C3%AD')
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$webRoot = Join-Path $repoRoot 'activity-story-map\web'
$webImagesRoot = Join-Path $webRoot 'images'
$charactersSource = Join-Path $ImagesRoot 'Characters'
$servicesSource = Join-Path $ImagesRoot 'Services'
$brandingSource = Join-Path $ImagesRoot 'Branding'
$charactersTarget = Join-Path $webImagesRoot 'characters'
$servicesTarget = Join-Path $webImagesRoot 'services'
$brandingTarget = Join-Path $webImagesRoot 'branding'

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
if (-not (Test-Path -LiteralPath $charactersSource)) { throw "Characters folder not found: $charactersSource" }
if (-not (Test-Path -LiteralPath $servicesSource)) { throw "Services folder not found: $servicesSource" }

New-Item -ItemType Directory -Force -Path $charactersTarget, $servicesTarget, $brandingTarget | Out-Null
Copy-Item -Path (Join-Path $charactersSource '*') -Destination $charactersTarget -Force
Copy-Item -Path (Join-Path $servicesSource '*') -Destination $servicesTarget -Force
if (Test-Path -LiteralPath $brandingSource) {
    Copy-Item -Path (Join-Path $brandingSource '*') -Destination $brandingTarget -Force
}

$characters = [ordered]@{}
Get-ChildItem -LiteralPath $charactersTarget -File | Sort-Object Name | ForEach-Object {
    $key = ConvertTo-AssetKey -Value $_.BaseName
    $characters[$key] = ConvertTo-WebPath -RelativePath "images\characters\$($_.Name)"
}

$services = [ordered]@{}
Get-ChildItem -LiteralPath $servicesTarget -File | Sort-Object Name | ForEach-Object {
    $key = ConvertTo-AssetKey -Value $_.BaseName
    $services[$key] = ConvertTo-WebPath -RelativePath "images\services\$($_.Name)"
}

if ($services.Contains('mail')) { $services['exchange.online'] = $services['mail'] }
if ($services.Contains('onedrive')) { $services['odb'] = $services['onedrive'] }
if ($services.Contains('sharepoint')) { $services['spo'] = $services['sharepoint'] }
if ($services.Contains('outlook')) {
    $services['microsoft.outlook'] = $services['outlook']
} elseif ($services.Contains('mail')) {
    $services['outlook'] = $services['mail']
    $services['microsoft.outlook'] = $services['mail']
}
if ($services.Contains('power.bi')) { $services['powerbi'] = $services['power.bi']; $services['microsoft.power.bi'] = $services['power.bi'] }
if ($services.Contains('powerbi')) { $services['power.bi'] = $services['powerbi']; $services['microsoft.power.bi'] = $services['powerbi'] }
if ($services.Contains('excel')) { $services['microsoft.excel'] = $services['excel'] }
if ($services.Contains('word')) { $services['microsoft.word'] = $services['word'] }
if ($services.Contains('powerpoint')) { $services['microsoft.powerpoint'] = $services['powerpoint'] }
if ($services.Contains('forms')) { $services['microsoft.forms'] = $services['forms'] }
if ($services.Contains('stream')) { $services['microsoft.stream'] = $services['stream'] }
if ($services.Contains('onenote')) { $services['one.note'] = $services['onenote']; $services['microsoft.onenote'] = $services['onenote'] }
if ($services.Contains('one.note')) { $services['onenote'] = $services['one.note']; $services['microsoft.onenote'] = $services['one.note'] }
if ($services.Contains('entra.id')) { $services['entra'] = $services['entra.id']; $services['microsoft.entra.id'] = $services['entra.id'] }
if ($services.Contains('entra')) { $services['entra.id'] = $services['entra']; $services['microsoft.entra.id'] = $services['entra'] }
if ($services.Contains('entraid')) { $services['entra.id'] = $services['entraid']; $services['entra'] = $services['entraid']; $services['microsoft.entra.id'] = $services['entraid'] }
if ($services.Contains('microsoft.purview')) { $services['purview'] = $services['microsoft.purview'] }
if ($services.Contains('purview')) { $services['microsoft.purview'] = $services['purview'] }
if ($services.Contains('microsoft.sentinel')) { $services['sentinel'] = $services['microsoft.sentinel'] }
if ($services.Contains('sentinel')) { $services['microsoft.sentinel'] = $services['sentinel'] }
if ($services.Contains('microsoft.defender')) { $services['defender'] = $services['microsoft.defender'] }
if ($services.Contains('defender')) { $services['microsoft.defender'] = $services['defender']; $services['defender.xdr'] = $services['defender'] }
if ($services.Contains('intune')) { $services['microsoft.intune'] = $services['intune'] }
if ($services.Contains('security.copilot')) { $services['microsoft.security.copilot'] = $services['security.copilot'] }
if ($services.Contains('securitycopilot')) { $services['security.copilot'] = $services['securitycopilot']; $services['microsoft.security.copilot'] = $services['securitycopilot'] }
if ($services.Contains('azure')) { $services['microsoft.azure'] = $services['azure']; $services['azure.portal'] = $services['azure'] }
if ($services.Contains('powershell')) { $services['power.shell'] = $services['powershell']; $services['microsoft.powershell'] = $services['powershell'] }

$branding = [ordered]@{}
Get-ChildItem -LiteralPath $brandingTarget -File | Sort-Object Name | ForEach-Object {
    $key = ConvertTo-AssetKey -Value $_.BaseName
    $branding[$key] = ConvertTo-WebPath -RelativePath "images\branding\$($_.Name)"
}

$manifest = [ordered]@{
    characters = $characters
    services = $services
    branding = $branding
}
$manifestPath = Join-Path $webImagesRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$storageAccountName = [string]$config.activityStoryMap.storageAccountName
$resourceGroup = [string]$config.activityStoryMap.resourceGroup
if (-not $storageAccountName -or -not $resourceGroup) {
    throw 'activityStoryMap.storageAccountName and activityStoryMap.resourceGroup must be configured.'
}

$siteKey = az storage account keys list -g $resourceGroup -n $storageAccountName --query '[0].value' -o tsv
if (-not $siteKey) { throw "Could not read storage key for '$storageAccountName'." }

az storage blob upload-batch --account-name $storageAccountName --account-key $siteKey -s $webRoot -d '$web' --overwrite true -o none | Out-Null

$noCachePatterns = @('*.html', '*.js', '*.css', '*.json')
foreach ($pattern in $noCachePatterns) {
    Get-ChildItem -LiteralPath $webRoot -Recurse -File -Filter $pattern | ForEach-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($webRoot, $_.FullName).Replace('\', '/')
        az storage blob update `
            --account-name $storageAccountName `
            --account-key $siteKey `
            --container-name '$web' `
            --name $relativePath `
            --content-cache-control 'no-cache, no-store, must-revalidate' `
            -o none | Out-Null
    }
}

if ($PurgeFrontDoor -and $config.activityStoryMap.frontDoor -and $config.activityStoryMap.frontDoor.enabled -eq $true) {
    $profileName = [string]$config.activityStoryMap.frontDoor.profileName
    $endpointName = [string]$config.activityStoryMap.frontDoor.endpointName
    if ($profileName -and $endpointName) {
        az afd endpoint purge `
            --resource-group $resourceGroup `
            --profile-name $profileName `
            --endpoint-name $endpointName `
            --content-paths '/*' `
            -o none | Out-Null
        Write-Host "Purged Azure Front Door endpoint: $endpointName" -ForegroundColor Green
    }
}

Write-Host "Published Activity Story Map assets to $($config.activityStoryMap.staticWebsiteUrl)" -ForegroundColor Green
Write-Host "Manifest: $($config.activityStoryMap.staticWebsiteUrl)images/manifest.json"
