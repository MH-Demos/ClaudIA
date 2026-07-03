# =============================================================================
# Common.Config.ps1 - config resolution, installation definitions, atomic JSON writes
# Split from modules\Common.ps1 (loaded by the Common.ps1 facade - callers
# keep dot-sourcing modules\Common.ps1 and see no difference).
# =============================================================================

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

function Sync-AAInstallationDefinitionsWithTenant {
    <#
    .SYNOPSIS
        Pair the ACTIVE state file (config\Installation_definitions.json) with
        the ACTIVE per-tenant config, so multi-tenant runs never overwrite each
        other's deployment state.
    .DESCRIPTION
        Installation_definitions.json is a single shared file read by 20+ tools.
        When per-tenant configs (config\tenants\<key>.json) are in use, this
        function keeps per-tenant archives at config\tenants\<key>.definitions.json
        and switches the active file to match the resolved config:
          - active state already belongs to the resolved tenant -> refresh archive
          - active state belongs to ANOTHER tenant -> archive it, then restore the
            resolved tenant's archive (or start fresh when none exists)
          - active state has no tenant identity (template/damaged) -> preserved
            under config\backups\ before being replaced, never silently lost
        Legacy single-tenant mode (config\agents.json) is a strict no-op.
    .PARAMETER RepoRoot
        Repository root containing config\.
    .PARAMETER ConfigPath
        The RESOLVED config path (output of Resolve-AATenantConfigPath).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$Quiet
    )

    $activePath = Join-Path $RepoRoot 'config\Installation_definitions.json'
    $tenantsDir = Join-Path $RepoRoot 'config\tenants'

    # Legacy single-tenant mode: resolved config is not under config\tenants\.
    $configDir = Split-Path -Parent $ConfigPath
    if (-not $configDir -or -not (Test-Path -LiteralPath $tenantsDir)) { return }
    $inTenantsDir = ([System.IO.Path]::GetFullPath($configDir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($tenantsDir).TrimEnd('\'))
    if (-not $inTenantsDir) { return }

    $expectedKey = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $expectedDefsPath = Join-Path $tenantsDir ($expectedKey + '.definitions.json')

    # Identify the owner of the current active state via its tenant domain.
    $activeKey = $null
    $activeExists = Test-Path -LiteralPath $activePath
    if ($activeExists) {
        try {
            $activeDefs = Get-Content -LiteralPath $activePath -Raw -Encoding utf8 | ConvertFrom-Json
            $activeDomain = [string]$activeDefs.tenant.domain
            if ($activeDomain -and $activeDomain -notin @('contoso.example', 'example.com', 'example.test')) {
                $activeKey = ConvertTo-AATenantConfigKey -Domain $activeDomain
            }
        } catch {
            $activeKey = $null # unreadable -> treated as unowned
        }
    }

    if ($activeKey -and ($activeKey -ieq $expectedKey)) {
        # Right tenant already active: refresh its archive copy (doubles as backup).
        Copy-Item -LiteralPath $activePath -Destination $expectedDefsPath -Force
        return
    }

    if ($activeKey) {
        # Active state belongs to another tenant: archive it under its own key.
        Copy-Item -LiteralPath $activePath -Destination (Join-Path $tenantsDir ($activeKey + '.definitions.json')) -Force
        if (-not $Quiet) { Write-Host "  [state] Archived installation definitions of tenant '$activeKey'." -ForegroundColor DarkCyan }
    } elseif ($activeExists) {
        # Unowned (template/damaged) state: preserve it in backups, never delete data.
        $backupDir = Join-Path $RepoRoot 'config\backups'
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $unownedPath = Join-Path $backupDir ("Installation_definitions.unowned-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Copy-Item -LiteralPath $activePath -Destination $unownedPath -Force
        if (-not $Quiet) { Write-Host "  [state] Active installation definitions had no tenant identity; preserved at $unownedPath." -ForegroundColor Yellow }
    }

    if (Test-Path -LiteralPath $expectedDefsPath) {
        Copy-Item -LiteralPath $expectedDefsPath -Destination $activePath -Force
        if (-not $Quiet) { Write-Host "  [state] Restored installation definitions of tenant '$expectedKey'." -ForegroundColor DarkCyan }
    } elseif ($activeExists) {
        Remove-Item -LiteralPath $activePath -Force
        if (-not $Quiet) { Write-Host "  [state] Starting fresh installation definitions for tenant '$expectedKey'." -ForegroundColor DarkCyan }
    }
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

    if ((Test-Path $Path) -and $Fresh) {
        # -Fresh bypasses the tenant guard by design; never let it silently
        # destroy real state (template-config full runs, incl. -DryRun, reach
        # this with Fresh=true). Preserve any tenant-owned file first.
        try {
            $preFresh = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
            $preFreshDomain = [string]$preFresh.tenant.domain
            if ($preFreshDomain -and $preFreshDomain -notin @('contoso.example', 'example.com', 'example.test')) {
                $backupDir = Join-Path (Split-Path -Parent $Path) 'backups'
                if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                $preFreshBackup = Join-Path $backupDir ("Installation_definitions.pre-fresh-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
                Copy-Item -LiteralPath $Path -Destination $preFreshBackup -Force
                Write-Host "  [state] Existing definitions of tenant '$preFreshDomain' preserved at $preFreshBackup before fresh start." -ForegroundColor Yellow
            }
        } catch {
            Write-Warning "Could not back up existing installation definitions before -Fresh: $($_.Exception.Message)"
        }
    }

    if ((Test-Path $Path) -and -not $Fresh) {
        $script:AAInstallationDefinitions = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json

        # Tenant-mismatch guard: never let a template config (blank/placeholder
        # domain) or another tenant's config overwrite real deployment state.
        # This is exactly the accident that corrupted the shared state file when
        # the installer ran without CLAUDIA_TENANT / -ConfigPath.
        $placeholders = @('', 'contoso.example', 'example.com', 'example.test')
        $existingDomain = [string]$script:AAInstallationDefinitions.tenant.domain
        $incomingDomain = [string]$Config.tenant.domain
        if ($existingDomain -and $existingDomain -notin $placeholders) {
            if ($incomingDomain -in $placeholders) {
                throw "Refusing to overwrite installation definitions of tenant '$existingDomain' with a config that has no tenant identity (template?). Set `$env:CLAUDIA_TENANT or pass -ConfigPath to select the right tenant, or delete '$Path' to start fresh."
            }
            if ($incomingDomain -ine $existingDomain) {
                throw "Refusing to overwrite installation definitions of tenant '$existingDomain' with config for '$incomingDomain'. Run Sync-AAInstallationDefinitionsWithTenant (the installer does this automatically), or delete '$Path' to start fresh."
            }
        }
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

function Save-AAJsonAtomic {
    # Atomic JSON file write: write to a temp file in the same directory,
    # validate the JSON round-trips, then swap it over the target. Prevents
    # truncated/corrupt agents.json or Installation_definitions.json when the
    # process is interrupted (Ctrl+C, crash, OneDrive sync lock) mid-write.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $Json -Encoding utf8 -ErrorAction Stop
    try {
        $null = (Get-Content -LiteralPath $tmp -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "Refusing to overwrite $Path -- staged JSON failed validation: $($_.Exception.Message)"
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
}

function Save-AAInstallationDefinitions {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:AAInstallationDefinitions) { return }
    $script:AAInstallationDefinitions.updatedAt = (Get-Date).ToString('o')
    Save-AAJsonAtomic -Path $Path -Json ($script:AAInstallationDefinitions | ConvertTo-Json -Depth 50)

    # Keep the per-tenant archive in sync so a later tenant switch restores
    # up-to-date state (see Sync-AAInstallationDefinitionsWithTenant). Key
    # derivation MUST match Sync's: the resolved config FILENAME when the
    # config lives under config\tenants\ (falling back to the tenant domain),
    # otherwise a filename/domain mismatch would let this mirror overwrite the
    # safety archive Sync just made.
    try {
        $tenantsDir = Join-Path (Split-Path -Parent $Path) 'tenants'
        if (Test-Path -LiteralPath $tenantsDir) {
            $key = $null
            $srcCfg = [string]$script:AAInstallationDefinitions.sourceConfigPath
            if ($srcCfg) {
                $srcDir = Split-Path -Parent $srcCfg
                if ($srcDir -and ([System.IO.Path]::GetFullPath($srcDir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($tenantsDir).TrimEnd('\'))) {
                    $key = [System.IO.Path]::GetFileNameWithoutExtension($srcCfg)
                }
            }
            if (-not $key) {
                $domain = [string]$script:AAInstallationDefinitions.tenant.domain
                if ($domain -and $domain -notin @('contoso.example', 'example.com', 'example.test')) {
                    $key = ConvertTo-AATenantConfigKey -Domain $domain
                }
            }
            if ($key) {
                Copy-Item -LiteralPath $Path -Destination (Join-Path $tenantsDir ($key + '.definitions.json')) -Force
            }
        }
    } catch {
        Write-Warning "Could not refresh the per-tenant definitions archive: $($_.Exception.Message)"
    }
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

