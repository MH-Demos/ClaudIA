<#PSScriptInfo

.VERSION 1.5.0

.GUID 4ad7a2b2-6c69-4f4a-aae5-2f7d0cf2f1ad

.AUTHOR
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Azure NameAvailability Preflight

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Pre-flight check that the globally-unique resource names Install-ClaudIA.ps1 will generate for the configured subscription are still available worldwide.

.RELEASENOTES
1.5.0 - Added ADX/tenant location alignment check. Public installs use tenant.location as the canonical region for every resource; adx.location must match unless deliberately overridden. When the two diverge, a new MISALIGNED row appears in the results table; with -AutoFix, adx.location is rewritten to tenant.location and ingestBaseUri / queryBaseUri mirrors are rebuilt with the corrected region. This catches drift left behind by manual edits, partial deploys, or capacity fallbacks that were not written back, all of which previously led the wizard to deploy the cluster in a different region than the rest of the infra. 1.4.0 - Added ADX SKU regional availability check (queries Microsoft.Kusto/locations/{region}/skus to verify the configured clusterSku is listed in adx.location with no subscription restrictions). The API does not expose runtime stockouts (Azure capacity exhaustion), so this is a best-effort sanity check that catches typos and unsupported region/SKU pairs before launching the cluster create. Extended AutoFix to sync all ADX mirror fields when adx.clusterName is renamed: adx.ingestBaseUri, adx.queryBaseUri, and activityStoryMap.source.clusterName (previously only adx.keyVaultName was kept in sync). 1.3.0 - Replaced DNS heuristic for ADX cluster with the Kusto ARM checkNameAvailability API (DNS lookup said 'available' for names already taken globally, causing InvalidClusterName mid-deploy). ADX cluster now participates in -AutoFix renaming. Added ownership detection: if a TAKEN globally-unique name already lives in the target subscription+RG, treat it as 'reusable' (the installer is idempotent) instead of triggering a rename that would orphan the existing resource. 1.2.0 - Replaced DNS heuristics for Key Vault and Azure OpenAI with the ARM checkNameAvailability / checkDomainAvailability APIs (DNS gave false negatives for KVs without public traffic, causing mid-deploy VaultAlreadyExists). Key Vault and Azure OpenAI now participate in -AutoFix renaming. 1.1.0 - Added -AutoFix switch: on collision, generate alternative globally-unique candidate names (deterministic SHA seed with retry iteration), write them back to agents.json (with backup), and re-export derived URLs (staticWebsiteUrl, apiBaseUrl). 1.0.0 - Initial version. Checks Azure OpenAI, Key Vault (with soft-delete lookup), Storage (checkNameAvailability API), Function App, and ADX cluster.

#>
<#
.SYNOPSIS
    Verify the unique resource names that the installer will use are available globally.

.DESCRIPTION
    Install-ClaudIA.ps1 generates names for globally-unique resources from a
    deterministic hash of (subscriptionId + resourceGroup). When you redeploy on
    a fresh subscription, those generated names should be available - but you
    cannot know for sure until something tries to create them.

    This script reproduces the same naming logic the installer uses, then runs
    a lightweight global availability check for each candidate name BEFORE you
    burn 10+ minutes hitting a collision mid-deployment.

    Checks performed:
      Azure OpenAI       DNS resolution of <name>.openai.azure.com
      Key Vault          DNS resolution of <name>.vault.azure.net
                         + az keyvault list-deleted (soft-delete poll)
      Storage (site)     ARM checkNameAvailability API
      Storage (function) ARM checkNameAvailability API
      Function App       DNS resolution of <name>.azurewebsites.net
      ADX cluster        ARM Microsoft.Kusto/locations/{region}/checkNameAvailability
                         (only if a cluster name is already pinned in config)

    All checks are read-only. No resources are created.

.PARAMETER ConfigPath
    Path to agents.json. Defaults to ..\config\agents.json relative to this script.

.PARAMETER InstallationDefinitionsPath
    Path to Installation_definitions.json. Defaults to ..\config\Installation_definitions.json.

.PARAMETER Detailed
    Show the seed material used to derive each name.

.EXAMPLE
    .\tools\Test-NameAvailability.ps1
    # Compute future names and report availability.

.EXAMPLE
    .\tools\Test-NameAvailability.ps1 -Detailed

.LINK
    .\tools\Reset-UniqueNames.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [switch]$Detailed,
    [switch]$AutoFix,
    [int]$MaxAttempts = 16
)

$ErrorActionPreference = 'Stop'

function New-AAShortSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
}

function Get-AANameBase {
    param([Parameter(Mandatory)][string]$Source, [int]$MaxLength = 12)
    $base = ($Source -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $base) { $base = 'agents' }
    if ($base.Length -gt $MaxLength) { $base = $base.Substring(0, $MaxLength) }
    return $base
}

function Get-StorageSafeName {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$DomainCode, [Parameter(Mandatory)][string]$Suffix)
    $name = ($Prefix + $DomainCode + $Suffix).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
    return $name
}

function Test-DnsExists {
    param([Parameter(Mandatory)][string]$HostName)
    try {
        $null = [System.Net.Dns]::GetHostEntry($HostName)
        return $true
    } catch {
        return $false
    }
}

function Test-StorageNameAvailability {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Name)
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Storage/checkNameAvailability?api-version=2023-05-01"
    $body = @{ name = $Name; type = 'Microsoft.Storage/storageAccounts' } | ConvertTo-Json -Compress
    try {
        $tmp = [IO.Path]::GetTempFileName()
        $body | Set-Content -LiteralPath $tmp -Encoding utf8
        $raw = & az rest --method post --url $url --body "@$tmp" -o json 2>$null
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ Available = $null; Reason = 'API call failed (not logged in?)' } }
        $r = $raw | ConvertFrom-Json
        return @{ Available = [bool]$r.nameAvailable; Reason = $r.reason; Message = $r.message }
    } catch {
        return @{ Available = $null; Reason = $_.Exception.Message }
    }
}

function Test-KeyVaultNameAvailability {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Name)
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01"
    $body = @{ name = $Name; type = 'Microsoft.KeyVault/vaults' } | ConvertTo-Json -Compress
    try {
        $tmp = [IO.Path]::GetTempFileName()
        $body | Set-Content -LiteralPath $tmp -Encoding utf8
        $raw = & az rest --method post --url $url --body "@$tmp" -o json 2>$null
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ Available = $null; Reason = 'API call failed (not logged in?)' } }
        $r = $raw | ConvertFrom-Json
        return @{ Available = [bool]$r.nameAvailable; Reason = $r.reason; Message = $r.message }
    } catch {
        return @{ Available = $null; Reason = $_.Exception.Message }
    }
}

function Test-OpenAIDomainAvailability {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Name)
    # ARM checkDomainAvailability for Microsoft.CognitiveServices subdomain (the custom domain used by Azure OpenAI).
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/checkDomainAvailability?api-version=2023-05-01"
    $body = @{ subdomainName = $Name; type = 'Microsoft.CognitiveServices/accounts' } | ConvertTo-Json -Compress
    try {
        $tmp = [IO.Path]::GetTempFileName()
        $body | Set-Content -LiteralPath $tmp -Encoding utf8
        $raw = & az rest --method post --url $url --body "@$tmp" -o json 2>$null
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ Available = $null; Reason = 'API call failed (not logged in?)' } }
        $r = $raw | ConvertFrom-Json
        return @{ Available = [bool]$r.isSubdomainAvailable; Reason = $r.reason; Message = $r.message }
    } catch {
        return @{ Available = $null; Reason = $_.Exception.Message }
    }
}

function Test-KeyVaultSoftDeleted {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $raw = & az keyvault list-deleted --query "[?name=='$Name'] | [0]" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw -or $raw.Trim() -eq 'null' -or $raw.Trim() -eq '') { return $false }
    return $true
}

function Test-AdxClusterNameAvailability {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Location
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Kusto/locations/$Location/checkNameAvailability?api-version=2023-08-15"
    $body = @{ name = $Name; type = 'Microsoft.Kusto/clusters' } | ConvertTo-Json -Compress
    try {
        $tmp = [IO.Path]::GetTempFileName()
        $body | Set-Content -LiteralPath $tmp -Encoding utf8
        $raw = & az rest --method post --url $url --body "@$tmp" -o json 2>$null
        Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ Available = $null; Reason = 'API call failed (not logged in?)' } }
        $r = $raw | ConvertFrom-Json
        return @{ Available = [bool]$r.nameAvailable; Reason = $r.reason; Message = $r.message }
    } catch {
        return @{ Available = $null; Reason = $_.Exception.Message }
    }
}

function Test-AdxSkuAvailability {
    # Best-effort regional SKU sanity check. Does NOT detect runtime stockouts -
    # Azure does not expose live cluster capacity. This only catches typos and
    # SKUs that are not offered in the chosen region / blocked for the subscription.
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Sku
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Kusto/locations/$Location/skus?api-version=2023-08-15"
    try {
        $raw = & az rest --method get --url $url -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return @{ Available = $null; Reason = 'API call failed (not logged in?)' } }
        $list = ($raw | ConvertFrom-Json).value | Where-Object { $_.resourceType -eq 'clusters' }
        $match = $list | Where-Object { $_.name -eq $Sku } | Select-Object -First 1
        if (-not $match) {
            $offered = ($list | Select-Object -ExpandProperty name) -join ', '
            return @{ Available = $false; Reason = 'SkuNotOfferedInRegion'; Message = "SKU '$Sku' is not listed in '$Location'. Offered: $offered" }
        }
        # PowerShell quirk: @($null).Count returns 1. Filter out nulls explicitly.
        $restr = @()
        if ($match.PSObject.Properties['restrictions'] -and $null -ne $match.restrictions) {
            $restr = @($match.restrictions | Where-Object { $_ })
        }
        if ($restr.Count -gt 0) {
            $rdesc = ($restr | ForEach-Object { "$($_.type)/$($_.reasonCode)" }) -join ';'
            return @{ Available = $false; Reason = 'SkuRestricted'; Message = "SKU '$Sku' in '$Location' is restricted: $rdesc" }
        }
        return @{ Available = $true; Reason = 'OK'; Message = "SKU '$Sku' listed in '$Location' with no restrictions" }
    } catch {
        return @{ Available = $null; Reason = $_.Exception.Message }
    }
}

function Test-ResourceExistsInRg {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$Name
    )
    # Returns $true if the resource is in our target sub+RG (idempotent reuse OK).
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $null = & az resource show --subscription $SubscriptionId -g $ResourceGroup --resource-type $ResourceType --name $Name -o none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-AvailableNameCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('openai','keyvault','storage','funcapp','adx')][string]$Kind,
        [Parameter(Mandatory)][string]$Seed,
        [Parameter(Mandatory)][string]$BaseDomain,
        [Parameter(Mandatory)][string]$DomainCode,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$Location,
        [int]$MaxAttempts = 16
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $sfx = New-AAShortSuffix -Seed "$Seed-retry$i"
        switch ($Kind) {
            'openai' {
                $name = ("oai-$BaseDomain-$sfx").ToLowerInvariant()
                if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
                $check = Test-OpenAIDomainAvailability -SubscriptionId $SubscriptionId -Name $name
                if ($check.Available) { return $name }
            }
            'keyvault' {
                $kvBase = $BaseDomain; if ($kvBase.Length -gt 10) { $kvBase = $kvBase.Substring(0, 10) }
                $name = ("kv$kvBase$sfx").ToLowerInvariant()
                if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
                $check = Test-KeyVaultNameAvailability -SubscriptionId $SubscriptionId -Name $name
                $sd    = Test-KeyVaultSoftDeleted -Name $name
                if ($check.Available -and -not $sd) { return $name }
            }
            'storage' {
                $name = Get-StorageSafeName -Prefix 'st' -DomainCode $DomainCode -Suffix $sfx
                $check = Test-StorageNameAvailability -SubscriptionId $SubscriptionId -Name $name
                if ($check.Available) { return $name }
            }
            'funcapp' {
                $name = ("func-$DomainCode-story-$sfx").ToLowerInvariant()
                if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
                if (-not (Test-DnsExists "$name.azurewebsites.net")) { return $name }
            }
            'adx' {
                # Kusto clusters: 4-22 chars, lowercase alphanumeric, must start with a letter.
                $adxBase = $BaseDomain; if ($adxBase.Length -gt 10) { $adxBase = $adxBase.Substring(0, 10) }
                $name = ("adx$adxBase$sfx").ToLowerInvariant() -replace '[^a-z0-9]', ''
                if ($name.Length -gt 22) { $name = $name.Substring(0, 22) }
                if (-not $Location) { throw "adx kind requires -Location" }
                $check = Test-AdxClusterNameAvailability -SubscriptionId $SubscriptionId -Name $name -Location $Location
                if ($check.Available) { return $name }
            }
        }
    }
    return $null
}

# ---- load + merge config like the installer does ----
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

$defs = $null
if (Test-Path -LiteralPath $InstallationDefinitionsPath) {
    $defs = Get-Content -LiteralPath $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
}

$sub        = [string]$config.tenant.subscriptionId
$rg         = [string]$config.infrastructure.resourceGroup
$location   = [string]$config.tenant.location
$domain     = [string]$config.tenant.domain
$domainLabel = ($domain -split '\.')[0]

if (-not $sub) { throw 'tenant.subscriptionId is empty in agents.json.' }
if (-not $rg)  { throw 'infrastructure.resourceGroup is empty in agents.json.' }

# ---- derive future names (mirror of Install-ClaudIA.ps1 + Deploy-ActivityStoryMap.ps1) ----
$baseDomain   = Get-AANameBase -Source $domainLabel -MaxLength 12
$baseRg       = Get-AANameBase -Source $rg -MaxLength 11
$domainCode   = ($domainLabel -replace '[^a-zA-Z0-9]', '').ToUpperInvariant()

$oaiName         = $config.infrastructure.openAiAccountName
if (-not $oaiName) { $oaiName = "oai-$baseDomain-$(New-AAShortSuffix -Seed "$sub-$rg-openai")" }

$kvName          = $config.infrastructure.keyVaultName
if (-not $kvName) {
    $kvBase = $baseDomain; if ($kvBase.Length -gt 10) { $kvBase = $kvBase.Substring(0, 10) }
    $kvName = "kv$kvBase$(New-AAShortSuffix -Seed "$sub-$rg-kv")"
}

$smSuffix        = New-AAShortSuffix -Seed "$sub-$rg-activity-story-map"
$siteStorage     = $config.activityStoryMap.storageAccountName
if (-not $siteStorage) { $siteStorage = Get-StorageSafeName -Prefix 'st' -DomainCode "${domainCode}map" -Suffix $smSuffix }
$fnStorage       = $config.activityStoryMap.functionStorageAccountName
if (-not $fnStorage)   { $fnStorage   = Get-StorageSafeName -Prefix 'st' -DomainCode "${domainCode}fn"  -Suffix $smSuffix }
$fnApp           = $config.activityStoryMap.functionAppName
if (-not $fnApp)       { $fnApp       = "func-$domainCode-story-$smSuffix" }

$adxClusterName  = $config.adx.clusterName
$adxRegion       = if ($config.adx.location) { $config.adx.location } else { $location }
$adxSku          = $config.adx.clusterSku

# ---- run checks ----
Write-Host ''
Write-Host '=== Test-NameAvailability ==='
Write-Host "  Subscription : $sub"
Write-Host "  RG / location: $rg / $location"
Write-Host ''

if ($Detailed) {
    Write-Host 'Seed material:' -ForegroundColor DarkGray
    Write-Host "  baseDomain  : $baseDomain"
    Write-Host "  domainCode  : $domainCode"
    Write-Host "  smSuffix    : $smSuffix"
    Write-Host ''
}

$results = New-Object System.Collections.Generic.List[object]

# Helper: turn a 'TAKEN' status into 'available (already in target RG)' when we already own the resource.
function Resolve-OwnedReuse {
    param([string]$Status, [string]$SubscriptionId, [string]$ResourceGroup, [string]$ResourceType, [string]$Name)
    if ($Status -notlike 'TAKEN*') { return $Status }
    $owned = Test-ResourceExistsInRg -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ResourceType $ResourceType -Name $Name
    if ($owned -eq $true) { return 'available (already in target RG)' }
    return $Status
}

# OpenAI (ARM checkDomainAvailability - more reliable than DNS)
$oaiCheck = Test-OpenAIDomainAvailability -SubscriptionId $sub -Name $oaiName
$oaiStatus = if ($null -eq $oaiCheck.Available) { "UNKNOWN ($($oaiCheck.Reason))" } elseif ($oaiCheck.Available) { 'available' } else { "TAKEN ($($oaiCheck.Reason))" }
$oaiStatus = Resolve-OwnedReuse -Status $oaiStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.CognitiveServices/accounts' -Name $oaiName
$results.Add([PSCustomObject]@{
    Resource = 'Azure OpenAI'
    Name     = $oaiName
    Check    = 'ARM checkDomainAvailability'
    Status   = $oaiStatus
})

# Key Vault (ARM checkNameAvailability + soft-delete poll)
$kvCheck = Test-KeyVaultNameAvailability -SubscriptionId $sub -Name $kvName
$softDel = Test-KeyVaultSoftDeleted -Name $kvName
$kvStatus = if ($null -eq $kvCheck.Available) { "UNKNOWN ($($kvCheck.Reason))" }
            elseif (-not $kvCheck.Available) { "TAKEN ($($kvCheck.Reason))" }
            elseif ($softDel) { 'TAKEN (soft-deleted)' }
            else { 'available' }
$kvStatus = Resolve-OwnedReuse -Status $kvStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.KeyVault/vaults' -Name $kvName
$results.Add([PSCustomObject]@{
    Resource = 'Key Vault'
    Name     = $kvName
    Check    = 'ARM checkNameAvailability + soft-delete poll'
    Status   = $kvStatus
})

# Storage (site)
$st = Test-StorageNameAvailability -SubscriptionId $sub -Name $siteStorage
$siteStatus = if ($null -eq $st.Available) { "UNKNOWN ($($st.Reason))" } elseif ($st.Available) { 'available' } else { "TAKEN ($($st.Reason))" }
$siteStatus = Resolve-OwnedReuse -Status $siteStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.Storage/storageAccounts' -Name $siteStorage
$results.Add([PSCustomObject]@{
    Resource = 'Storage (site)'
    Name     = $siteStorage
    Check    = 'ARM checkNameAvailability'
    Status   = $siteStatus
})

# Storage (function)
$st = Test-StorageNameAvailability -SubscriptionId $sub -Name $fnStorage
$fnStorageStatus = if ($null -eq $st.Available) { "UNKNOWN ($($st.Reason))" } elseif ($st.Available) { 'available' } else { "TAKEN ($($st.Reason))" }
$fnStorageStatus = Resolve-OwnedReuse -Status $fnStorageStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.Storage/storageAccounts' -Name $fnStorage
$results.Add([PSCustomObject]@{
    Resource = 'Storage (fn)'
    Name     = $fnStorage
    Check    = 'ARM checkNameAvailability'
    Status   = $fnStorageStatus
})

# Function App
$dns = "$fnApp.azurewebsites.net"
$fnAppStatus = if (Test-DnsExists $dns) { 'TAKEN' } else { 'available' }
$fnAppStatus = Resolve-OwnedReuse -Status $fnAppStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.Web/sites' -Name $fnApp
$results.Add([PSCustomObject]@{
    Resource = 'Function App'
    Name     = $fnApp
    Check    = "DNS $dns"
    Status   = $fnAppStatus
})

# ADX cluster (only if pinned)
if ($adxClusterName) {
    $adxCheck = Test-AdxClusterNameAvailability -SubscriptionId $sub -Name $adxClusterName -Location $adxRegion
    $adxStatus = if ($null -eq $adxCheck.Available) { "UNKNOWN ($($adxCheck.Reason))" } elseif ($adxCheck.Available) { 'available' } else { "TAKEN ($($adxCheck.Reason))" }
    $adxStatus = Resolve-OwnedReuse -Status $adxStatus -SubscriptionId $sub -ResourceGroup $rg -ResourceType 'Microsoft.Kusto/clusters' -Name $adxClusterName
    $results.Add([PSCustomObject]@{
        Resource = 'ADX cluster'
        Name     = $adxClusterName
        Check    = "ARM Kusto checkNameAvailability ($adxRegion)"
        Status   = $adxStatus
    })
    if ($adxSku) {
        $skuCheck = Test-AdxSkuAvailability -SubscriptionId $sub -Location $adxRegion -Sku $adxSku
        $skuStatus = if ($null -eq $skuCheck.Available) { "UNKNOWN ($($skuCheck.Reason))" }
                     elseif ($skuCheck.Available) { 'available' }
                     else { "BLOCKED ($($skuCheck.Reason))" }
        $results.Add([PSCustomObject]@{
            Resource = 'ADX SKU'
            Name     = $adxSku
            Check    = "ARM Microsoft.Kusto/locations/$adxRegion/skus (regional listing - NOT a runtime capacity probe)"
            Status   = $skuStatus
        })
    }
    # ADX/tenant location alignment: the public installer uses tenant.location as the
    # canonical region. Drift (manual edits, partial deploys, un-written-back fallbacks)
    # leads the cluster to land in a different region than KV/OAI/Storage, breaking the
    # workbook + Story Map links. MISALIGNED is auto-fixable (-AutoFix).
    if ($adxRegion -and $location -and $adxRegion -ne $location) {
        $results.Add([PSCustomObject]@{
            Resource = 'ADX location'
            Name     = $adxRegion
            Check    = "adx.location vs tenant.location"
            Status   = "MISALIGNED (tenant=$location)"
        })
    }
} else {
    $results.Add([PSCustomObject]@{
        Resource = 'ADX cluster'
        Name     = '(not yet generated)'
        Check    = 'skipped'
        Status   = 'will be generated at Step 7 (random suffix)'
    })
}

Write-Host ''
$results | Format-Table Resource, Name, Status -AutoSize

$blockers   = @($results | Where-Object { $_.Status -like 'TAKEN*' -or $_.Status -like 'BLOCKED*' })
$unknowns   = @($results | Where-Object { $_.Status -like 'UNKNOWN*' })
$misaligned = @($results | Where-Object { $_.Status -like 'MISALIGNED*' })

# ADX/tenant location drift is auto-fixable and not a blocker. Handle it up front so the
# rest of the report can stay focused on real name collisions.
if ($misaligned.Count -gt 0) {
    Write-Host ''
    Write-Host "[WARN] $($misaligned.Count) configuration drift detected:" -ForegroundColor Yellow
    foreach ($m in $misaligned) { Write-Host "  - $($m.Resource): $($m.Name) -> $($m.Status)" -ForegroundColor Yellow }

    if ($AutoFix -and $config.adx -and $location -and $config.adx.location -ne $location) {
        $backupDir = Join-Path (Split-Path $ConfigPath -Parent) 'backups'
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bakName = [IO.Path]::GetFileNameWithoutExtension($ConfigPath) + ".$stamp.bak" + [IO.Path]::GetExtension($ConfigPath)
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir $bakName) -Force
        Write-Host "  Backed up: $(Join-Path $backupDir $bakName)" -ForegroundColor DarkGray

        $oldRegion = [string]$config.adx.location
        $config.adx.location = $location
        $clusterForUri = if ($config.adx.PSObject.Properties['clusterName']) { [string]$config.adx.clusterName } else { $null }
        if ($clusterForUri) {
            if ($config.adx.PSObject.Properties['ingestBaseUri']) { $config.adx.ingestBaseUri = "https://$clusterForUri.$location.kusto.windows.net" }
            if ($config.adx.PSObject.Properties['queryBaseUri'])  { $config.adx.queryBaseUri  = "https://$clusterForUri.$location.kusto.windows.net" }
        }
        $config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
        Write-Host "  Realigned: adx.location $oldRegion -> $location (+ ingest/query URIs)" -ForegroundColor Green
        $adxRegion = $location  # so downstream messages reflect the new region
    } else {
        Write-Host '  Re-run with -AutoFix to realign adx.location with tenant.location automatically.' -ForegroundColor DarkGray
    }
}

if ($blockers.Count -gt 0) {
    Write-Host ''
    Write-Host "[FAIL] $($blockers.Count) name(s) already in use globally:" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host "  - $($b.Resource): $($b.Name) -> $($b.Status)" -ForegroundColor Red }

    if ($AutoFix) {
        Write-Host ''
        Write-Host '-AutoFix enabled: generating alternative globally-unique candidates...' -ForegroundColor Cyan
        $renames = New-Object System.Collections.Generic.List[object]
        $stillBlocked = New-Object System.Collections.Generic.List[object]
        foreach ($b in $blockers) {
            switch ($b.Resource) {
                'Azure OpenAI'   { $kind = 'openai';   $jsonPath = 'infrastructure.openAiAccountName';            $purposeSeed = "$sub-$rg-openai";                  $dc = $domainCode }
                'Key Vault'      { $kind = 'keyvault'; $jsonPath = 'infrastructure.keyVaultName';                 $purposeSeed = "$sub-$rg-kv";                      $dc = $domainCode }
                'Storage (site)' { $kind = 'storage';  $jsonPath = 'activityStoryMap.storageAccountName';         $purposeSeed = "$sub-$rg-activity-story-map-site"; $dc = "${domainCode}map" }
                'Storage (fn)'   { $kind = 'storage';  $jsonPath = 'activityStoryMap.functionStorageAccountName'; $purposeSeed = "$sub-$rg-activity-story-map-fn";   $dc = "${domainCode}fn" }
                'Function App'   { $kind = 'funcapp'; $jsonPath = 'activityStoryMap.functionAppName';             $purposeSeed = "$sub-$rg-activity-story-map-func"; $dc = $domainCode }
                'ADX cluster'    { $kind = 'adx';      $jsonPath = 'adx.clusterName';                              $purposeSeed = "$sub-$rg-adx-cluster";             $dc = $domainCode }
                default          { $stillBlocked.Add($b); continue }
            }
            $candidate = New-AvailableNameCandidate -Kind $kind -Seed $purposeSeed -BaseDomain $baseDomain -DomainCode $dc -SubscriptionId $sub -Location $adxRegion -MaxAttempts $MaxAttempts
            if ($candidate) {
                Write-Host ("  {0,-16} {1,-22} -> {2}" -f $b.Resource, $b.Name, $candidate) -ForegroundColor Green
                $renames.Add([PSCustomObject]@{ Path = $jsonPath; Old = $b.Name; New = $candidate; Resource = $b.Resource })
            } else {
                Write-Host ("  {0,-16} {1,-22} -> NO CANDIDATE FOUND after {2} attempts" -f $b.Resource, $b.Name, $MaxAttempts) -ForegroundColor Red
                $stillBlocked.Add($b)
            }
        }

        if ($renames.Count -gt 0) {
            $backupDir = Join-Path (Split-Path $ConfigPath -Parent) 'backups'
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $bakName = [IO.Path]::GetFileNameWithoutExtension($ConfigPath) + ".$stamp.bak" + [IO.Path]::GetExtension($ConfigPath)
            $bak = Join-Path $backupDir $bakName
            Copy-Item -LiteralPath $ConfigPath -Destination $bak -Force
            Write-Host "  Backed up: $bak" -ForegroundColor DarkGray

            foreach ($r in $renames) {
                $parts = $r.Path -split '\.'
                $cursor = $config
                for ($i = 0; $i -lt $parts.Length - 1; $i++) { $cursor = $cursor.$($parts[$i]) }
                $cursor.$($parts[-1]) = $r.New
            }
            # Sync mirror fields (same value lives under multiple sections)
            $newKv = ($renames | Where-Object { $_.Path -eq 'infrastructure.keyVaultName' } | Select-Object -First 1).New
            if ($newKv -and $config.adx -and $config.adx.PSObject.Properties['keyVaultName']) {
                $config.adx.keyVaultName = $newKv
            }
            $newSite = ($renames | Where-Object { $_.Path -eq 'activityStoryMap.storageAccountName' } | Select-Object -First 1).New
            $newFn   = ($renames | Where-Object { $_.Path -eq 'activityStoryMap.functionAppName'    } | Select-Object -First 1).New
            if ($newSite -and $config.activityStoryMap) { $config.activityStoryMap.staticWebsiteUrl = "https://$newSite.z22.web.core.windows.net/" }
            if ($newFn   -and $config.activityStoryMap) { $config.activityStoryMap.apiBaseUrl = "https://$newFn.azurewebsites.net" }
            # When ADX cluster is renamed, sync every place that mirrors the cluster name or URIs.
            $newAdx = ($renames | Where-Object { $_.Path -eq 'adx.clusterName' } | Select-Object -First 1).New
            if ($newAdx) {
                if ($config.adx -and $config.adx.PSObject.Properties['ingestBaseUri']) {
                    $config.adx.ingestBaseUri = "https://$newAdx.$adxRegion.kusto.windows.net"
                }
                if ($config.adx -and $config.adx.PSObject.Properties['queryBaseUri']) {
                    $config.adx.queryBaseUri = "https://$newAdx.$adxRegion.kusto.windows.net"
                }
                if ($config.activityStoryMap -and $config.activityStoryMap.PSObject.Properties['source'] -and $config.activityStoryMap.source.PSObject.Properties['clusterName']) {
                    $config.activityStoryMap.source.clusterName = $newAdx
                }
            }

            $config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
            Write-Host "  Updated: $ConfigPath ($($renames.Count) field(s))" -ForegroundColor Green
        }

        if ($stillBlocked.Count -eq 0) {
            Write-Host ''
            Write-Host '[OK] All collisions auto-resolved with new candidate names. Re-run the installer to use them.' -ForegroundColor Green
            exit 0
        } else {
            Write-Host ''
            Write-Host "[FAIL] $($stillBlocked.Count) collision(s) could not be auto-resolved after $MaxAttempts attempts." -ForegroundColor Red
            Write-Host '  Try changing tenant.subscriptionId or infrastructure.resourceGroup to alter the deterministic seed.' -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Host ''
    Write-Host 'Remediation:' -ForegroundColor Yellow
    Write-Host '  Re-run with -AutoFix to generate alternative names automatically:' -ForegroundColor Yellow
    Write-Host '    .\tools\Test-NameAvailability.ps1 -AutoFix' -ForegroundColor Cyan
    Write-Host '  Or edit agents.json manually and re-run this script.' -ForegroundColor Yellow
    exit 1
}

if ($unknowns.Count -gt 0) {
    Write-Host ''
    Write-Host "[WARN] $($unknowns.Count) check(s) could not be completed (likely not signed in to az)." -ForegroundColor Yellow
    Write-Host '  Run "az login" then retry.' -ForegroundColor Yellow
    exit 2
}

Write-Host ''
Write-Host '[OK] All future unique names are available globally.' -ForegroundColor Green
exit 0
