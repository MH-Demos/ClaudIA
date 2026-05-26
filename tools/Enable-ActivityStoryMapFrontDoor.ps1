<#PSScriptInfo

.VERSION 1.0.0

.GUID 754010c6-7fb3-4e2d-8790-92d61691ed8d

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
Enables Azure Front Door for the Activity Story Map static website

.RELEASENOTES
Initial version metadata for Enables Azure Front Door for the Activity Story Map static website.

#>
<#
.SYNOPSIS
    Enables Azure Front Door for the Activity Story Map static website.
.DESCRIPTION
    Creates or updates a Standard Azure Front Door profile, endpoint, origin
    group, origin, route, and optional custom domain for the Activity Story Map.
    The frontend still calls the Azure Function API directly through config.js,
    so the script also adds the Front Door hostnames to Function App CORS.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$CustomDomain = '',
    [string]$EndpointName,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function Get-ShortHash {
    param([Parameter(Mandatory)][string]$Text, [int]$Length = 6)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, $Length)).ToLowerInvariant()
}

function Get-DomainCode {
    param([Parameter(Mandatory)][string]$Domain)
    $label = ($Domain -split '\.')[0]
    $code = ($label -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $code) { $code = 'agents' }
    return $code
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($WhatIf) {
        Write-Host "WhatIf: az $($Arguments -join ' ')" -ForegroundColor Yellow
        return $null
    }
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

function Invoke-AzCliWithFallback {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string[]]$FallbackArguments,
        [Parameter(Mandatory)][string]$FallbackPattern
    )

    if ($WhatIf) {
        Write-Host "WhatIf: az $($Arguments -join ' ')" -ForegroundColor Yellow
        return $null
    }

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) { return $output }

    $text = ($output | Out-String)
    if ($text -match $FallbackPattern) {
        Write-Host "  [WARN] Azure CLI does not support one optional argument; retrying with compatible command." -ForegroundColor Yellow
        $fallbackOutput = & az @FallbackArguments 2>&1
        if ($LASTEXITCODE -eq 0) { return $fallbackOutput }
        throw "Azure CLI command failed: az $($FallbackArguments -join ' ')`n$($fallbackOutput | Out-String)"
    }

    throw "Azure CLI command failed: az $($Arguments -join ' ')`n$text"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $config.activityStoryMap -or $config.activityStoryMap.enabled -ne $true) {
    throw 'Activity Story Map must be deployed before enabling Front Door.'
}

$subscriptionId = [string]$config.tenant.subscriptionId
$domainCode = Get-DomainCode -Domain ([string]$config.tenant.domain)
$resourceGroup = if ($config.activityStoryMap.resourceGroup) { [string]$config.activityStoryMap.resourceGroup } else { [string]$config.infrastructure.resourceGroup }
$suffix = Get-ShortHash -Text "$subscriptionId-$resourceGroup-activity-story-map"
$profileName = if ($config.activityStoryMap.frontDoor.profileName) { [string]$config.activityStoryMap.frontDoor.profileName } else { "afd-$domainCode-story-$suffix" }
$endpointName = if ($EndpointName) { $EndpointName } elseif ($config.activityStoryMap.frontDoor.endpointName) { [string]$config.activityStoryMap.frontDoor.endpointName } else { "activitymap-$domainCode-$suffix" }
$originGroupName = if ($config.activityStoryMap.frontDoor.originGroupName) { [string]$config.activityStoryMap.frontDoor.originGroupName } else { 'og-storymap' }
$originName = if ($config.activityStoryMap.frontDoor.originName) { [string]$config.activityStoryMap.frontDoor.originName } else { 'origin-storage-staticweb' }
$routeName = if ($config.activityStoryMap.frontDoor.routeName) { [string]$config.activityStoryMap.frontDoor.routeName } else { 'route-storymap' }
$staticWebsiteUrl = [string]$config.activityStoryMap.staticWebsiteUrl
$functionAppName = [string]$config.activityStoryMap.functionAppName
if (-not $CustomDomain -and $config.activityStoryMap.frontDoor -and $config.activityStoryMap.frontDoor.customDomain) {
    $savedCustomDomain = [string]$config.activityStoryMap.frontDoor.customDomain
    if ($savedCustomDomain -and $savedCustomDomain -notmatch 'contoso\.example|example\.com|example\.test') {
        $CustomDomain = $savedCustomDomain
    }
}

if (-not $staticWebsiteUrl) { throw 'activityStoryMap.staticWebsiteUrl is required.' }
if (-not $functionAppName) { throw 'activityStoryMap.functionAppName is required.' }

$originHost = ([System.Uri]$staticWebsiteUrl).Host

Write-Host 'Activity Story Map Front Door plan' -ForegroundColor Cyan
Write-Host "  Resource group: $resourceGroup"
Write-Host "  Profile:        $profileName"
Write-Host "  Endpoint:       $endpointName"
Write-Host "  Origin:         $originHost"
Write-Host "  Custom domain:  $CustomDomain"

Invoke-AzCli @('account','set','--subscription',$subscriptionId)
Invoke-AzCli @('provider','register','--namespace','Microsoft.Cdn','--wait','-o','none')

$profileExists = az afd profile show -g $resourceGroup --profile-name $profileName --query name -o tsv 2>$null
if (-not $profileExists) {
    Invoke-AzCli @('afd','profile','create','-g',$resourceGroup,'--profile-name',$profileName,'--sku','Standard_AzureFrontDoor','-o','none')
}

$originGroupExists = az afd origin-group show -g $resourceGroup --profile-name $profileName --origin-group-name $originGroupName --query name -o tsv 2>$null
if (-not $originGroupExists) {
    Invoke-AzCli @(
        'afd','origin-group','create','-g',$resourceGroup,'--profile-name',$profileName,
        '--origin-group-name',$originGroupName,'--probe-request-type','HEAD',
        '--probe-protocol','Https','--probe-interval-in-seconds','120',
        '--probe-path','/','--sample-size','4','--successful-samples-required','3',
        '--additional-latency-in-milliseconds','50','-o','none'
    )
}

$originExists = az afd origin show -g $resourceGroup --profile-name $profileName --origin-group-name $originGroupName --origin-name $originName --query name -o tsv 2>$null
if (-not $originExists) {
    $originCreateArgs = @(
        'afd','origin','create','-g',$resourceGroup,'--profile-name',$profileName,
        '--origin-group-name',$originGroupName,'--origin-name',$originName,
        '--host-name',$originHost,'--origin-host-header',$originHost,
        '--http-port','80','--https-port','443','--priority','1','--weight','1000',
        '--enabled-state','Enabled','--enable-certificate-name-check','true','-o','none'
    )
    $originCreateFallbackArgs = @(
        'afd','origin','create','-g',$resourceGroup,'--profile-name',$profileName,
        '--origin-group-name',$originGroupName,'--origin-name',$originName,
        '--host-name',$originHost,'--origin-host-header',$originHost,
        '--http-port','80','--https-port','443','--priority','1','--weight','1000',
        '--enabled-state','Enabled','-o','none'
    )
    Invoke-AzCliWithFallback -Arguments $originCreateArgs -FallbackArguments $originCreateFallbackArgs -FallbackPattern 'unrecognized arguments|enable-certificate-name-check' | Out-Null
}

$endpointExists = az afd endpoint show -g $resourceGroup --profile-name $profileName --endpoint-name $endpointName --query name -o tsv 2>$null
if (-not $endpointExists) {
    Invoke-AzCli @('afd','endpoint','create','-g',$resourceGroup,'--profile-name',$profileName,'--endpoint-name',$endpointName,'--enabled-state','Enabled','-o','none')
}

$routeExists = az afd route show -g $resourceGroup --profile-name $profileName --endpoint-name $endpointName --route-name $routeName --query name -o tsv 2>$null
if (-not $routeExists) {
    Invoke-AzCli @(
        'afd','route','create','-g',$resourceGroup,'--profile-name',$profileName,
        '--endpoint-name',$endpointName,'--route-name',$routeName,
        '--origin-group',$originGroupName,'--supported-protocols','Http','Https',
        '--patterns-to-match','/*','--forwarding-protocol','HttpsOnly',
        '--https-redirect','Enabled','--link-to-default-domain','Enabled','-o','none'
    )
} else {
    Invoke-AzCli @(
        'afd','route','update','-g',$resourceGroup,'--profile-name',$profileName,
        '--endpoint-name',$endpointName,'--route-name',$routeName,
        '--enabled-state','Enabled','--https-redirect','Enabled',
        '--forwarding-protocol','HttpsOnly','-o','none'
    )
}

if ($WhatIf) {
    Write-Host ''
    Write-Host 'WhatIf complete. No Front Door resources were changed.' -ForegroundColor Yellow
    return
}

$endpointHostName = az afd endpoint show -g $resourceGroup --profile-name $profileName --endpoint-name $endpointName --query hostName -o tsv
$validationToken = $null

if ($CustomDomain) {
    $customDomainName = ($CustomDomain -replace '[^a-zA-Z0-9]', '-').Trim('-').ToLowerInvariant()
    $customDomainExists = az afd custom-domain show -g $resourceGroup --profile-name $profileName --custom-domain-name $customDomainName --query name -o tsv 2>$null
    if (-not $customDomainExists) {
        Invoke-AzCli @(
            'afd','custom-domain','create','-g',$resourceGroup,'--profile-name',$profileName,
            '--custom-domain-name',$customDomainName,'--host-name',$CustomDomain,
            '--certificate-type','ManagedCertificate','--minimum-tls-version','TLS12','-o','none'
        )
    }
    Invoke-AzCli @(
        'afd','route','update','-g',$resourceGroup,'--profile-name',$profileName,
        '--endpoint-name',$endpointName,'--route-name',$routeName,
        '--custom-domains',$customDomainName,'-o','none'
    )
    $validationToken = az afd custom-domain show -g $resourceGroup --profile-name $profileName --custom-domain-name $customDomainName --query validationProperties.validationToken -o tsv
}

foreach ($origin in @("https://$endpointHostName", "https://$CustomDomain")) {
    if ($origin -and $origin -ne 'https://') {
        az functionapp cors add -g $resourceGroup -n $functionAppName --allowed-origins $origin -o none 2>$null | Out-Null
    }
}

$frontDoorConfig = [ordered]@{
    enabled = $true
    profileName = $profileName
    endpointName = $endpointName
    endpointHostName = $endpointHostName
    endpointUrl = "https://$endpointHostName/"
    originGroupName = $originGroupName
    originName = $originName
    routeName = $routeName
    customDomain = $CustomDomain
    customDomainUrl = if ($CustomDomain) { "https://$CustomDomain/" } else { $null }
    validationTxtRecord = if ($CustomDomain) { "_dnsauth.$(($CustomDomain -split '\.')[0])" } else { $null }
    validationToken = $validationToken
    cnameTarget = $endpointHostName
}

Set-AAObjectProperty -Object $config.activityStoryMap -Name 'frontDoor' -Value $frontDoorConfig
$config.activityStoryMap.launchUrl = if ($CustomDomain) { "https://$CustomDomain/" } else { "https://$endpointHostName/" }
$config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8

if (Test-Path -LiteralPath $InstallationDefinitionsPath) {
    $defs = Get-Content -LiteralPath $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $defs.activityStoryMap) {
        Set-AAObjectProperty -Object $defs -Name 'activityStoryMap' -Value ([PSCustomObject][ordered]@{})
    }
    Set-AAObjectProperty -Object $defs.activityStoryMap -Name 'frontDoor' -Value $frontDoorConfig
    if (-not $defs.steps) { Set-AAObjectProperty -Object $defs -Name 'steps' -Value ([PSCustomObject][ordered]@{}) }
    $step8 = $defs.steps.PSObject.Properties['8']
    if ($step8) {
        Set-AAObjectProperty -Object $step8.Value -Name 'frontDoorEndpointUrl' -Value $frontDoorConfig.endpointUrl
        Set-AAObjectProperty -Object $step8.Value -Name 'frontDoorCustomDomainUrl' -Value $frontDoorConfig.customDomainUrl
    }
    $defs.updatedAt = (Get-Date).ToString('o')
    $defs | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $InstallationDefinitionsPath -Encoding utf8
}

Write-Host ''
Write-Host 'Azure Front Door is configured.' -ForegroundColor Green
Write-Host "  Endpoint: https://$endpointHostName/"
if ($CustomDomain) {
    Write-Host "  DNS CNAME: $CustomDomain -> $endpointHostName"
    Write-Host "  DNS TXT:   $($frontDoorConfig.validationTxtRecord) -> $validationToken"
}

return [PSCustomObject]$frontDoorConfig



