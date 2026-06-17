<#PSScriptInfo

.VERSION 1.0.2

.GUID a0c76a45-5021-47b3-98a4-626b744a5f58

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
Common script

.RELEASENOTES
Version 1.0.2 adds partial deployment result status support.

#>
function Invoke-AAAzCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not $env:CLAUDIA_M365_AZURE_CONFIG_DIR) {
        return (& az @Arguments)
    }

    $oldConfigDir = $env:AZURE_CONFIG_DIR
    $env:AZURE_CONFIG_DIR = $env:CLAUDIA_M365_AZURE_CONFIG_DIR
    try {
        & az @Arguments
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

function New-AALabPassword {
    # Cryptographically random password with replacement (repeated chars allowed)
    # and at least one char from each class. Get-Random -Count samples WITHOUT
    # replacement and is not a crypto RNG, so it must not be used for passwords.
    param([int]$Length = 20)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!#$%'
    $all = $upper + $lower + $digit + $symbol
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([string]$Set)
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $Set[[System.BitConverter]::ToUInt32($bytes, 0) % $Set.Length]
        }
        $chars = [System.Collections.Generic.List[char]]::new()
        $chars.Add((& $pick $upper))
        $chars.Add((& $pick $lower))
        $chars.Add((& $pick $digit))
        $chars.Add((& $pick $symbol))
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
        # Fisher-Yates shuffle with the same RNG so class-guaranteed chars are not predictable prefixes
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $j = [System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    } finally {
        $rng.Dispose()
    }
}

function Write-AASecretLine {
    # Shows a secret on screen WITHOUT recording it in the PowerShell transcript:
    # Start-Transcript captures the PowerShell output streams (Write-Host included)
    # but not direct console writes. Falls back to nothing in non-interactive hosts.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Secret
    )
    try {
        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        [Console]::WriteLine("  ${Label}: $Secret")
        [Console]::ResetColor()
        Write-Host "  ${Label}: ******** (shown on screen only; not written to the log)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  ${Label}: ******** (console unavailable; value not displayed)" -ForegroundColor DarkGray
    }
}

function Set-AAKeyVaultSecretValue {
    # Writes a Key Vault secret without exposing the value on the az command line
    # (command lines are visible to other local processes and can land in shell
    # history / audit logs). The value is passed through a transient temp file.
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aakv-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # File.WriteAllText writes UTF-8 without BOM and without a trailing newline,
        # which matches the default --encoding utf-8 of 'az keyvault secret set --file'.
        [System.IO.File]::WriteAllText($tmp, $Value)
        az keyvault secret set --vault-name $VaultName --name $Name --file $tmp -o none 2>$null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-AgentUpn {
    param(
        [Parameter(Mandatory)]$Agent,
        [string]$Domain
    )
    if ($Agent.userPrincipalName) {
        $configuredUpn = [string]$Agent.userPrincipalName
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ($Agent.upn) {
        $configuredUpn = [string]$Agent.upn
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ("$($Agent.sam)" -match '@') { return [string]$Agent.sam }
    if ([string]::IsNullOrWhiteSpace($Domain)) { return [string]$Agent.sam }
    return "$($Agent.sam)@$Domain"
}

function Get-AgentSecretName {
    param(
        [Parameter(Mandatory)]$Agent,
        [string]$Domain
    )

    $upn = Get-AgentUpn -Agent $Agent -Domain $Domain
    $local = ($upn -split '@')[0].ToLowerInvariant()
    $name = $local -replace '[^a-z0-9-]', '-'
    $name = $name -replace '-+', '-'
    return $name.Trim('-')
}

function Get-KeyVaultName {
    param($Config)

    if ($Config.infrastructure.keyVaultName) { return [string]$Config.infrastructure.keyVaultName }

    $seed = "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-aa"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $suffix = ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
    $base = ($Config.infrastructure.resourceGroup -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($base.Length -gt 11) { $base = $base.Substring(0, 11) }
    return "kv$base$suffix"
}

function Get-AAGlobalSuffix {
    # Deterministic 8-char suffix (sub + RG) for globally-unique resource names
    # (Azure OpenAI account, storage). Mirrors Get-KeyVaultName seeding so all
    # derived names for a given (subscription, resourceGroup) stay stable across
    # reruns. ASCII/lowercase only.
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string]$Salt = ''
    )
    $seed = "$SubscriptionId-$ResourceGroup-$Salt"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
}

function Set-AAInfrastructureDefaults {
    # HIGH#3: the shared agents.json template ships with BLANK infrastructure
    # names so it carries no tenant identity. When the wizard only captures the
    # resource group, the remaining names (automation account, Azure OpenAI
    # account, Key Vault) used to stay empty and the deployment failed with
    # "$kvName" / empty-name errors. This fills any blank name deterministically:
    #   - automationAccountName -> 'aa-claudia-lab' (RG-scoped, name reuse is safe)
    #   - openAiAccountName      -> 'oai-claudia-<suffix>' (globally unique)
    #   - keyVaultName           -> Get-KeyVaultName (globally unique)
    # Explicit values from a per-tenant config or Installation_definitions.json
    # always win (only blanks are filled), so existing deployments are untouched.
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.infrastructure) { return $Config }
    $sub = [string]$Config.tenant.subscriptionId
    $rg  = [string]$Config.infrastructure.resourceGroup

    if ([string]::IsNullOrWhiteSpace([string]$Config.infrastructure.automationAccountName)) {
        Set-AAObjectProperty -Object $Config.infrastructure -Name 'automationAccountName' -Value 'aa-claudia-lab'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.infrastructure.openAiAccountName)) {
        $oaiName = if ($sub -and $rg) { "oai-claudia-$(Get-AAGlobalSuffix -SubscriptionId $sub -ResourceGroup $rg -Salt 'oai')" } else { 'oai-claudia-lab' }
        Set-AAObjectProperty -Object $Config.infrastructure -Name 'openAiAccountName' -Value $oaiName
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.infrastructure.keyVaultName)) {
        Set-AAObjectProperty -Object $Config.infrastructure -Name 'keyVaultName' -Value (Get-KeyVaultName -Config $Config)
    }
    # Keep the adx mirror of keyVaultName coherent when present and blank.
    if ($Config.adx -and [string]::IsNullOrWhiteSpace([string]$Config.adx.keyVaultName)) {
        Set-AAObjectProperty -Object $Config.adx -Name 'keyVaultName' -Value ([string]$Config.infrastructure.keyVaultName)
    }
    return $Config
}

function Set-AAObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Merge-AAInstallationDefinitionsIntoConfig {
    param(
        [Parameter(Mandatory)]$Config,
        $Definitions
    )

    if (-not $Definitions) { return $Config }

    if ($Definitions.tenant) {
        foreach ($prop in @('domain','tenantId','subscriptionId','location','country')) {
            if ($Definitions.tenant.PSObject.Properties[$prop] -and $null -ne $Definitions.tenant.$prop -and "$($Definitions.tenant.$prop)" -ne '') {
                Set-AAObjectProperty -Object $Config.tenant -Name $prop -Value $Definitions.tenant.$prop
            }
        }
    }

    if ($Definitions.infrastructure) {
        foreach ($prop in @(
            'resourceGroup','automationAccountName','openAiAccountName','openAiModel',
            'openAiModelVersion','openAiImageModel','openAiImageModelVersion','openAiTpm',
            'workbookEnabled','fabricEnabled','keyVaultName'
        )) {
            if ($Definitions.infrastructure.PSObject.Properties[$prop]) {
                Set-AAObjectProperty -Object $Config.infrastructure -Name $prop -Value $Definitions.infrastructure.$prop
            }
        }
    }

    if ($Definitions.adx) {
        if ($Config.PSObject.Properties['adx']) {
            $Config.adx = $Definitions.adx
        } else {
            $Config | Add-Member -NotePropertyName adx -NotePropertyValue $Definitions.adx -Force
        }
    } elseif ($Definitions.steps -and $Definitions.steps.PSObject.Properties['4'] -and $Definitions.steps.'4'.adx) {
        if ($Config.PSObject.Properties['adx']) {
            $Config.adx = $Definitions.steps.'4'.adx
        } else {
            $Config | Add-Member -NotePropertyName adx -NotePropertyValue $Definitions.steps.'4'.adx -Force
        }
    }

    if ($Definitions.agents -and @($Definitions.agents).Count -gt 0) {
        $Config.agents = @($Definitions.agents)
    } elseif ($Definitions.selectedUsers -and @($Definitions.selectedUsers).Count -gt 0) {
        $Config.agents = @($Definitions.selectedUsers)
    }

    return $Config
}

function Get-AAEffectiveConfig {
    param(
        [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\agents.json'),
        [string]$InstallationDefinitionsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\Installation_definitions.json'),
        [switch]$RequireInstallationDefinitions
    )

    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

    $definitions = $null
    if (Test-Path $InstallationDefinitionsPath) {
        $definitions = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
        $config = Merge-AAInstallationDefinitionsIntoConfig -Config $config -Definitions $definitions
    } elseif ($RequireInstallationDefinitions) {
        throw "Installation definitions not found: $InstallationDefinitionsPath"
    }

    # Fill any blank infrastructure names deterministically (template ships blank
    # so it carries no tenant identity). Explicit/definition values win; only
    # empties are derived. Prevents empty-name / "$kvName" deployment failures.
    $config = Set-AAInfrastructureDefaults -Config $config

    return [PSCustomObject]@{
        Config = $config
        Definitions = $definitions
        ConfigPath = $ConfigPath
        InstallationDefinitionsPath = $InstallationDefinitionsPath
    }
}

function Get-AADataAgentGraphScopes {
    return @(
        [PSCustomObject]@{ Id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'; Type = 'Scope'; Value = 'User.Read' }
        [PSCustomObject]@{ Id = 'b4e74841-8e56-480b-be8b-910348b18b4c'; Type = 'Scope'; Value = 'Mail.ReadWrite' }
        [PSCustomObject]@{ Id = 'e383f46e-2787-4529-855e-0e479a3ffac0'; Type = 'Scope'; Value = 'Mail.Send' }
        [PSCustomObject]@{ Id = '863451e7-0667-486c-a5d6-d135439485f0'; Type = 'Scope'; Value = 'Files.ReadWrite.All' }
        [PSCustomObject]@{ Id = '640ddd16-e5b7-4d71-9690-3f4022f5acd2'; Type = 'Scope'; Value = 'Sites.ReadWrite.All' }
        [PSCustomObject]@{ Id = '9ff7295e-131b-4d94-90e1-69fde507ac11'; Type = 'Scope'; Value = 'Chat.ReadWrite' }
        [PSCustomObject]@{ Id = '38826093-1571-4db0-8f04-29f0a5a46a30'; Type = 'Scope'; Value = 'ChannelMessage.Send' }
        [PSCustomObject]@{ Id = '485be79e-c497-4b35-9400-0e3fa7f2a5d4'; Type = 'Scope'; Value = 'Chat.Create' }
        [PSCustomObject]@{ Id = '660b7406-55f1-41ca-a0ed-0b035e182f3e'; Type = 'Scope'; Value = 'Team.ReadBasic.All' }
        [PSCustomObject]@{ Id = '37f7f235-527c-4136-accd-4a02d197296e'; Type = 'Scope'; Value = 'openid' }
        [PSCustomObject]@{ Id = '7427e0e9-2fba-42fe-b0c0-848c9e6a8182'; Type = 'Scope'; Value = 'offline_access' }
        [PSCustomObject]@{ Id = ''; Type = 'Scope'; Value = 'InformationProtectionPolicy.Read' }
    )
}

function Ensure-AADataAgentGraphConsent {
    param([Parameter(Mandatory)][string]$AppId)

    $graphId = '00000003-0000-0000-c000-000000000000'
    $scopes = @(Get-AADataAgentGraphScopes)
    $scopeText = ($scopes | ForEach-Object { $_.Value }) -join ' '

    Invoke-AAAzCommand -Arguments @('ad','app','update','--id',$AppId,'--is-fallback-public-client','true','-o','none') 2>$null

    $graphToken = Invoke-AAAzCommand -Arguments @('account','get-access-token','--resource','https://graph.microsoft.com','--query','accessToken','-o','tsv') 2>$null
    if (-not $graphToken) { throw "Could not acquire Microsoft Graph token. Run az login with a Global Admin or Privileged Role Admin account." }
    $graphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }

    $appObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $appObject) { throw "Application '$AppId' was not found in Microsoft Graph." }

    $spObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $spObject) {
        Invoke-AAAzCommand -Arguments @('ad','sp','create','--id',$AppId,'-o','none') 2>$null
        Start-Sleep -Seconds 5
        $spObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    }
    if (-not $spObject) { throw "Service principal for app '$AppId' was not found or could not be created." }

    $graphSp = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $graphSp) { throw "Microsoft Graph service principal was not found in this tenant." }

    $resolvedScopes = @()
    foreach ($scope in $scopes) {
        $scopeId = $scope.Id
        if ([string]::IsNullOrWhiteSpace($scopeId)) {
            $scopeId = ($graphSp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope.Value } | Select-Object -First 1).id
        }
        if (-not $scopeId) {
            throw "Microsoft Graph delegated permission '$($scope.Value)' was not found in this tenant."
        }
        $resolvedScopes += [PSCustomObject]@{ Id = $scopeId; Type = $scope.Type; Value = $scope.Value }
    }

    $manifestBody = @{
        requiredResourceAccess = @(
            @{
                resourceAppId = $graphId
                resourceAccess = @($resolvedScopes | ForEach-Object { @{ id = $_.Id; type = $_.Type } })
            }
        )
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($appObject.id)" `
        -Headers $graphHeaders -Body $manifestBody | Out-Null

    $grants = @((Invoke-RestMethod "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($spObject.id)' and resourceId eq '$($graphSp.id)'" -Headers $graphHeaders).value)
    $tenantGrant = $grants | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if ($tenantGrant) {
        Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($tenantGrant.id)" `
            -Headers $graphHeaders -Body (@{ scope = $scopeText } | ConvertTo-Json) | Out-Null
    } else {
        $grantBody = @{
            clientId    = $spObject.id
            consentType = 'AllPrincipals'
            resourceId  = $graphSp.id
            scope       = $scopeText
        } | ConvertTo-Json -Depth 4
        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            -Headers $graphHeaders -Body $grantBody | Out-Null
    }

    Invoke-AAAzCommand -Arguments @('ad','app','permission','admin-consent','--id',$AppId) 2>$null
    $updatedGrants = @((Invoke-RestMethod "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($spObject.id)' and resourceId eq '$($graphSp.id)'" -Headers $graphHeaders).value)
    $updatedTenantGrant = $updatedGrants | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if (-not $updatedTenantGrant) {
        throw "Tenant-wide delegated consent (AllPrincipals) was not found after repair."
    }

    return [PSCustomObject]@{
        AppId = $AppId
        ServicePrincipalId = $spObject.id
        Scope = $scopeText
        TenantGrantId = $updatedTenantGrant.id
        ExistingPrincipalGrantCount = @($updatedGrants | Where-Object { $_.consentType -eq 'Principal' }).Count
    }
}

function Set-AADeploymentResult {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$MainActivity,
        [Parameter(Mandatory)][ValidateSet('deployed','partial','skipped','failed')][string]$Status,
        [string]$Comments = ''
    )

    if (-not $script:AADeploymentResults) { $script:AADeploymentResults = @() }
    $script:AADeploymentResults += [PSCustomObject]@{
        Step = $Step
        'Main Activity' = $MainActivity
        Status = $Status
        Comments = $Comments
    }
}

function Write-AALongRunningNotice {
    param([string]$Activity)

    Write-Host "  $Activity can take several minutes. Please be patient while Azure finishes provisioning." -ForegroundColor DarkYellow
}

# Tracks resources whose publicNetworkAccess had to be flipped back to Enabled
# during this wizard run. Used by Write-AAHardeningTenantWarning to emit a single,
# actionable warning if the host tenant re-hardens nightly (MCAPS / Microsoft
# Managed Environment / hardened test tenants frequently apply Azure Policy that
# flips publicNetworkAccess back to Disabled on KV, Cognitive Services,
# Automation, Storage, ADX, etc.).
if (-not $Global:AAFlippedPnaResources) {
    $Global:AAFlippedPnaResources = [System.Collections.ArrayList]::new()
}

function Ensure-AAResourcePublicNetworkEnabled {
    <#
    .SYNOPSIS
        Idempotently flip a resource's properties.publicNetworkAccess back to 'Enabled'.
    .DESCRIPTION
        Many ClaudIA components (Key Vault writes from the operator workstation,
        Azure OpenAI control-plane deployments, Automation Account variable writes,
        ADX cluster ingestion) require the data plane to be publicly reachable from
        the wizard host. MCAPS / Microsoft Managed Environment / hardened test
        tenants apply Azure Policy that flips publicNetworkAccess to Disabled on a
        daily schedule. This helper checks the current state via ARM and, if it
        is anything other than 'Enabled', issues a single PATCH/POST to re-enable
        it. On success the resource is recorded in $Global:AAFlippedPnaResources
        so Write-AAHardeningTenantWarning can surface a single, actionable banner.
        On failure (subscription policy denial, RBAC gap) it writes a clear
        warning and returns $false so the caller can decide to continue or throw.
    .PARAMETER ResourceId
        ARM resource id of the resource. Must include subscription/RG/provider/name.
    .PARAMETER ApiVersion
        ARM API version that exposes properties.publicNetworkAccess for the type.
    .PARAMETER DisplayName
        Short label for logs (e.g. "Key Vault kv-foo").
    .PARAMETER ResourceTypeLabel
        Short label shown in the hardening banner (e.g. "Key Vault", "ADX cluster").
    #>
    param(
        [Parameter(Mandatory)] [string]$ResourceId,
        [Parameter(Mandatory)] [string]$ApiVersion,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$ResourceTypeLabel
    )

    $url = "https://management.azure.com${ResourceId}?api-version=${ApiVersion}"
    $current = az rest --method GET --url $url -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $current) {
        Write-Host "  [WARN] Could not read publicNetworkAccess for $DisplayName (skipping reachability check)." -ForegroundColor Yellow
        return $false
    }
    try {
        $resource = $current | ConvertFrom-Json
    } catch {
        Write-Host "  [WARN] Could not parse ARM response for $DisplayName (skipping reachability check)." -ForegroundColor Yellow
        return $false
    }

    $pna = $null
    if ($resource.properties) { $pna = $resource.properties.publicNetworkAccess }
    if (-not $pna) { return $true }            # property not exposed; treat as OK
    if ($pna -eq 'Enabled') { return $true }   # already reachable

    Write-Host "  [INFO] $DisplayName has publicNetworkAccess='$pna'. Re-enabling it so the wizard can reach the data plane..." -ForegroundColor DarkYellow
    $patchBody = '{"properties":{"publicNetworkAccess":"Enabled"}}'
    $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "aa-pna-$([guid]::NewGuid()).json"
    Set-Content -Path $bodyPath -Value $patchBody -Encoding utf8
    try {
        az rest --method PATCH --url $url --headers 'Content-Type=application/json' --body "@$bodyPath" -o none 2>$null
        if ($LASTEXITCODE -eq 0) {
            [void]$Global:AAFlippedPnaResources.Add([PSCustomObject]@{ Type=$ResourceTypeLabel; Name=$DisplayName; Id=$ResourceId })
            Write-Host "  [OK] $DisplayName publicNetworkAccess set to Enabled." -ForegroundColor Green
            return $true
        }
    } finally {
        if (Test-Path $bodyPath) { Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "  [WARN] Could not flip publicNetworkAccess for $DisplayName. The subscription likely enforces an Azure Policy that keeps it Disabled." -ForegroundColor Yellow
    Write-Host "         Remediation options:" -ForegroundColor Yellow
    Write-Host "           1. Open the resource in the portal -> Networking -> set 'All networks', then rerun this step." -ForegroundColor Yellow
    Write-Host "           2. Run this step from a workstation that has private-endpoint reachability to the resource." -ForegroundColor Yellow
    Write-Host "           3. Ask the subscription owner to exempt the resource from the Deny policy." -ForegroundColor Yellow
    return $false
}

function Test-AAMcapsHardenedTenant {
    <#
    .SYNOPSIS
        Return $true when the tenant domain matches the MCAPS / Microsoft Managed
        Environment hardened-tenant pattern (MngEnvMCAP*).
    .DESCRIPTION
        MCAPS / Microsoft Managed Environment lab tenants always carry an
        onmicrosoft.com domain of the form 'MngEnvMCAP<digits>.onmicrosoft.com'.
        These tenants apply a nightly Modify-effect Azure Policy that flips
        publicNetworkAccess back to Disabled on Key Vault, Cognitive Services,
        Automation, Storage and ADX, which takes the lab (and the Activity Story
        Map public static website) offline overnight. This deterministic domain
        check lets the wizard offer the daily reachability runbook as an automatic
        fallback for exactly these tenants, without changing behaviour for public /
        non-hardened tenants where auto-granting Contributor would be unexpected.
    .PARAMETER Domain
        The tenant primary domain (e.g. $Config.tenant.domain).
    #>
    param([string]$Domain)
    if (-not $Domain) { return $false }
    return ($Domain -match '(?i)MngEnvMCAP')
}

function ConvertTo-AATenantConfigKey {
    <#
    .SYNOPSIS
        Derive the short, filesystem-safe per-tenant config key from a tenant
        domain (e.g. 'contoso.onmicrosoft.com' -> 'contoso').
    .DESCRIPTION
        Per-tenant config files live in config\tenants\<key>.json. The key is the
        first DNS label of the tenant primary domain, stripped of anything that is
        not a letter, digit, dash or underscore so it is always a valid file name.
        Returns an empty string when no usable domain is supplied.
    .PARAMETER Domain
        The tenant primary domain (e.g. 'contoso.onmicrosoft.com').
    #>
    param([string]$Domain)
    if (-not $Domain) { return '' }
    $label = ($Domain -split '\.')[0]
    if (-not $label) { return '' }
    return ($label -replace '[^A-Za-z0-9_-]', '')
}

function Resolve-AATenantConfigPath {
    <#
    .SYNOPSIS
        Resolve which agents.json config file to use, with per-tenant overrides so
        a single repository can drive deployments into many tenants without the
        shared config file drifting (one tenant's auto-renamed resource names
        clobbering another's).
    .DESCRIPTION
        ClaudIA persists deployment state (auto-renamed globally-unique resource
        names, selected users, etc.) back into the active config file. With a
        single shared config\agents.json this means deploying a second tenant
        overwrites the first tenant's resolved names. Per-tenant config files keep
        each tenant's state isolated.

        Resolution order (first match wins):
          1. -ExplicitPath          (an operator-supplied -ConfigPath always wins)
          2. env:CLAUDIA_TENANT     -> config\tenants\<value>.json
          3. current az login domain (auto-detect) -> config\tenants\<key>.json
          4. config\agents.json     (legacy single-tenant fallback - unchanged)

        Steps 2 and 3 only select a per-tenant file when it actually exists on
        disk, so behaviour is identical to today for anyone who has not created a
        config\tenants\ folder. Auto-detect is best-effort: any failure to read
        the current az account silently falls through to the legacy fallback.
    .PARAMETER RepoRoot
        Repository root that contains the config\ folder.
    .PARAMETER ExplicitPath
        An operator-supplied config path. When non-empty it is returned as-is.
    .PARAMETER Quiet
        Suppress the informational line describing which file was selected.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ExplicitPath,
        [switch]$Quiet
    )

    if ($ExplicitPath) { return $ExplicitPath }

    $tenantsDir = Join-Path $RepoRoot 'config\tenants'
    $legacyPath = Join-Path $RepoRoot 'config\agents.json'

    $selectByKey = {
        param([string]$Key, [string]$Reason)
        if (-not $Key) { return $null }
        $candidate = Join-Path $tenantsDir ($Key + '.json')
        if (Test-Path -LiteralPath $candidate) {
            if (-not $Quiet) {
                Write-Host ("  [config] Using per-tenant config: config\tenants\{0}.json ({1})" -f $Key, $Reason) -ForegroundColor DarkCyan
            }
            return $candidate
        }
        return $null
    }

    # 2. Explicit env override.
    if ($env:CLAUDIA_TENANT) {
        $envKey = ConvertTo-AATenantConfigKey -Domain $env:CLAUDIA_TENANT
        $hit = & $selectByKey $envKey 'CLAUDIA_TENANT'
        if ($hit) { return $hit }
        if (-not $Quiet) {
            Write-Host ("  [config] CLAUDIA_TENANT='{0}' set but config\tenants\{1}.json not found; falling back." -f $env:CLAUDIA_TENANT, $envKey) -ForegroundColor Yellow
        }
    }

    # 3. Auto-detect from the current az login.
    try {
        $domain = (Invoke-AAAzCommand -Arguments @('account','show','--query','user.name','-o','tsv') 2>$null)
        if ($domain) { $domain = ([string]$domain).Trim() }
        # user.name is usually an admin UPN (admin@contoso.onmicrosoft.com);
        # take the domain part after '@' when present.
        if ($domain -and $domain.Contains('@')) { $domain = ($domain -split '@')[-1] }
        $autoKey = ConvertTo-AATenantConfigKey -Domain $domain
        $hit = & $selectByKey $autoKey 'auto-detected from az login'
        if ($hit) { return $hit }
    } catch {
        # best-effort only; fall through to legacy
    }

    # 4. Legacy single-tenant fallback.
    return $legacyPath
}

function Write-AAHardeningTenantWarning {
    <#
    .SYNOPSIS
        Emit a single, actionable banner if the wizard had to flip
        publicNetworkAccess back to Enabled on one or more resources this run.
    .DESCRIPTION
        MCAPS / Microsoft Managed Environment / hardened lab tenants typically
        apply Azure Policy daily that:
          - flips Key Vault / Cognitive Services / Automation / Storage / ADX
            publicNetworkAccess to Disabled,
          - auto-stops Dev/Basic SKU ADX clusters and other compute,
          - revokes ROPC + blocks app passwords via Conditional Access.
        If we had to re-enable anything during this wizard run, that is the
        signal the host tenant is on such a policy schedule. Emit a single
        warning so the operator knows the lab will degrade overnight unless
        they put automation in place to repeat the wizard's reachability fixes
        on a schedule (Azure Automation runbook, Logic App, GitHub Action,
        cron job from a Hybrid Runbook Worker, etc.).
    #>
    if (-not $Global:AAFlippedPnaResources -or $Global:AAFlippedPnaResources.Count -eq 0) { return }

    Write-Host ""
    Write-Host "  ==================== HARDENED TENANT DETECTED ====================" -ForegroundColor Yellow
    Write-Host "  This wizard had to re-enable publicNetworkAccess on:" -ForegroundColor Yellow
    foreach ($r in $Global:AAFlippedPnaResources) {
        Write-Host ("    - {0,-22} {1}" -f $r.Type, $r.Name) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  This pattern matches MCAPS / Microsoft Managed Environment / hardened test tenants" -ForegroundColor Yellow
    Write-Host "  that re-apply 'Deny public network access' Azure Policy on a daily schedule." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Without ongoing automation, the lab will degrade overnight:" -ForegroundColor Yellow
    Write-Host "    - Key Vault writes/reads from the operator workstation will return ForbiddenByConnection." -ForegroundColor Yellow
    Write-Host "    - ADX Dev/Basic clusters auto-stop after ~5 days of inactivity and need start + PNA flip." -ForegroundColor Yellow
    Write-Host "    - Azure OpenAI / Automation Account control-plane writes will hit network-deny." -ForegroundColor Yellow
    Write-Host "    - Browser-agent local runs that read KV secrets will fail." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Recommended fix (turnkey): deploy the bundled daily reachability runbook." -ForegroundColor Yellow
    Write-Host "    .\tools\Deploy-LabReachabilityRunbook.ps1 -ResourceGroup <your-rg>" -ForegroundColor Green
    Write-Host "  This uploads tools\Restore-LabPublicNetworkAccess.ps1 as a runbook in the ClaudIA" -ForegroundColor Yellow
    Write-Host "  Automation Account, grants the AA managed identity Contributor on the RG, and" -ForegroundColor Yellow
    Write-Host "  schedules it daily at 06:00 UTC to re-enable PNA + start the ADX cluster if Stopped." -ForegroundColor Yellow
    Write-Host "  Full background + alternatives: docs\mcaps-hardened-tenant.md" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Also worth knowing about MCAPS / hardened tenants (NOT auto-handled by the wizard):" -ForegroundColor Yellow
    Write-Host "    - VMs are auto-deallocated at off-hours (no impact on ClaudIA today, but matters" -ForegroundColor Yellow
    Write-Host "      if you add Hybrid Runbook Workers, ADX VNet injection, or a self-hosted IR)." -ForegroundColor Yellow
    Write-Host "    - Conditional Access often blocks ROPC and Resource Owner Password Grant. If you" -ForegroundColor Yellow
    Write-Host "      enable BrowserAgent persona logins, exclude grp-claudia-agent-mfa-exclusion from" -ForegroundColor Yellow
    Write-Host "      MFA + 'Block legacy auth' policies." -ForegroundColor Yellow
    Write-Host "    - Cognitive Services + Storage often have 'disableLocalAuth=true' enforced. ClaudIA" -ForegroundColor Yellow
    Write-Host "      already uses managed identity for OAI, so this is fine; if you add Storage to the" -ForegroundColor Yellow
    Write-Host "      Activity Story Map, set allowSharedKeyAccess=false and use SAS / Entra auth only." -ForegroundColor Yellow
    Write-Host "    - Key Vault soft-deleted secrets get purged on a 7-30 day cycle; do not rely on" -ForegroundColor Yellow
    Write-Host "      'Recover deleted secret' for production secrets." -ForegroundColor Yellow
    Write-Host "  ===================================================================" -ForegroundColor Yellow
    Write-Host ""
}

function Close-AAConnections {
    param([switch]$IncludeAzureCliLogout)

    $closed = [ordered]@{
        PowerShellSessions = 0
        ExchangeOnline = 'not-loaded'
        MicrosoftGraph = 'not-loaded'
        AzContext = 'not-loaded'
        PnPOnline = 'not-loaded'
        AzureCli = if ($IncludeAzureCliLogout) { 'requested' } else { 'preserved' }
        Errors = @()
    }

    try {
        $sessions = @(Get-PSSession -ErrorAction SilentlyContinue)
        if ($sessions.Count -gt 0) {
            $sessions | Remove-PSSession -ErrorAction SilentlyContinue
            $closed.PowerShellSessions = $sessions.Count
        }
    } catch { $closed.Errors += "PSSession: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $closed.ExchangeOnline = 'closed'
        }
    } catch { $closed.Errors += "ExchangeOnline: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $closed.MicrosoftGraph = 'closed'
        }
    } catch { $closed.Errors += "MicrosoftGraph: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-AzAccount -ErrorAction SilentlyContinue) {
            Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
            Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
            $closed.AzContext = 'closed-process-scope'
        }
    } catch { $closed.Errors += "AzContext: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-PnPOnline -ErrorAction SilentlyContinue) {
            Disconnect-PnPOnline -ErrorAction SilentlyContinue | Out-Null
            $closed.PnPOnline = 'closed'
        }
    } catch { $closed.Errors += "PnPOnline: $($_.Exception.Message)" }

    if ($IncludeAzureCliLogout) {
        try {
            az logout 2>$null
            $closed.AzureCli = 'logged-out'
        } catch { $closed.Errors += "AzureCli: $($_.Exception.Message)" }
    }

    return [PSCustomObject]$closed
}

function Initialize-AAInstallationDefinitions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunLogPath,
        [Parameter(Mandatory)][string]$RunStamp,
        [switch]$Fresh
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    if ((Test-Path $Path) -and -not $Fresh) {
        $script:AAInstallationDefinitions = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    } else {
        $script:AAInstallationDefinitions = [PSCustomObject][ordered]@{
            schemaVersion = '1.0'
            runId = $RunStamp
            createdAt = (Get-Date).ToString('o')
            updatedAt = (Get-Date).ToString('o')
            sourceConfigPath = $ConfigPath
            runLogPath = $RunLogPath
            tenant = [ordered]@{}
            infrastructure = [ordered]@{}
            agents = @()
            selectedUsers = @()
            environmentScan = [ordered]@{}
            steps = [ordered]@{}
            sessionReset = $null
            notes = @()
        }
    }

    $script:AAInstallationDefinitions.sourceConfigPath = $ConfigPath
    $script:AAInstallationDefinitions.runLogPath = $RunLogPath
    $script:AAInstallationDefinitions.tenant = [ordered]@{
        domain = $Config.tenant.domain
        tenantId = $Config.tenant.tenantId
        subscriptionId = $Config.tenant.subscriptionId
        location = $Config.tenant.location
        country = $Config.tenant.country
    }
    $script:AAInstallationDefinitions.infrastructure = [ordered]@{
        resourceGroup = $Config.infrastructure.resourceGroup
        automationAccountName = $Config.infrastructure.automationAccountName
        openAiAccountName = $Config.infrastructure.openAiAccountName
        openAiModel = $Config.infrastructure.openAiModel
        openAiModelVersion = $Config.infrastructure.openAiModelVersion
        openAiImageModel = $Config.infrastructure.openAiImageModel
        openAiImageModelVersion = $Config.infrastructure.openAiImageModelVersion
        openAiTpm = $Config.infrastructure.openAiTpm
        fabricEnabled = $Config.infrastructure.fabricEnabled
        keyVaultName = Get-KeyVaultName -Config $Config
    }
    $script:AAInstallationDefinitions.agents = @($Config.agents | ForEach-Object {
        [ordered]@{
            sam = $_.sam
            userPrincipalName = if ($_.userPrincipalName) { $_.userPrincipalName } else { $null }
            displayName = $_.displayName
            department = $_.department
            jobTitle = $_.jobTitle
            wave = $_.wave
            workload = $_.workload
            copilotLicense = $_.copilotLicense
            existingUser = $_.existingUser
            workingHours = $_.workingHours
            filesPerDay = $_.filesPerDay
            emailsPerDay = $_.emailsPerDay
            style = $_.style
            topics = $_.topics
            keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $Config.tenant.domain
        }
    })
    if ($Config.adx) {
        if ($script:AAInstallationDefinitions.PSObject.Properties['adx']) {
            $script:AAInstallationDefinitions.adx = $Config.adx
        } else {
            $script:AAInstallationDefinitions | Add-Member -NotePropertyName adx -NotePropertyValue $Config.adx -Force
        }
    }

    Save-AAInstallationDefinitions -Path $Path
}

function Save-AAInstallationDefinitions {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:AAInstallationDefinitions) { return }
    $script:AAInstallationDefinitions.updatedAt = (Get-Date).ToString('o')
    $script:AAInstallationDefinitions | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding utf8
}

function Set-AAInstallationDefinition {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)]$Value
    )

    if (-not $script:AAInstallationDefinitions) { return }
    if ($script:AAInstallationDefinitions.PSObject.Properties[$Section]) {
        $script:AAInstallationDefinitions.$Section = $Value
    } else {
        $script:AAInstallationDefinitions | Add-Member -NotePropertyName $Section -NotePropertyValue $Value -Force
    }
    Save-AAInstallationDefinitions -Path $Path
}

function Set-AAInstallationStepDefinition {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)]$Value
    )

    if (-not $script:AAInstallationDefinitions) { return }
    # Add-Member -NotePropertyName rejects some numeric strings because they can
    # be converted to PSMemberTypes enum values. PSNoteProperty avoids that trap.
    if (-not $script:AAInstallationDefinitions.steps) {
        $script:AAInstallationDefinitions.steps = [PSCustomObject][ordered]@{}
    }
    $existing = $script:AAInstallationDefinitions.steps.PSObject.Properties[$Step]
    if ($existing) {
        $existing.Value = $Value
    } else {
        $script:AAInstallationDefinitions.steps.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new($Step, $Value)
        )
    }
    Save-AAInstallationDefinitions -Path $Path
}



