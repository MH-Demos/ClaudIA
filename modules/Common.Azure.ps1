# =============================================================================
# Common.Azure.ps1 - az CLI, Key Vault, Graph consent, PNA handling, connections
# Split from modules\Common.ps1 (loaded by the Common.ps1 facade - callers
# keep dot-sourcing modules\Common.ps1 and see no difference).
# =============================================================================

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

