<#PSScriptInfo

.VERSION 1.1.0
.GUID eae37755-6eb4-444f-9e77-e8d699645e18

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
ClaudIA - Interactive Deployment Wizard

.RELEASENOTES
Version 1.1.0 natively integrates the cross-tenant pre-flight: clears persisted globally-unique resource names when the subscription changes (Step 0) and verifies worldwide name availability before any resource is created (Step 4 pre-flight). In -Auto mode the pre-flight passes -AutoFix so colliding names are rewritten in agents.json with alternative deterministic candidates and the installer reloads the config in-place before deploying.

#>
<#
.SYNOPSIS
    ClaudIA - Interactive Deployment Wizard
.DESCRIPTION
    Single entry point to deploy autonomous data-generation agents that simulate
    corporate employees in an M365 tenant. Generates realistic PII content
    (files, emails, Teams posts, Copilot queries) for Purview DLP/IRM/DSPM testing.

    Supports two user modes:
      - CREATE (default): Creates new Entra ID users from agents.json personas
      - EXISTING: Interactive picker to select existing tenant users as agents

    WARNING: Uses ROPC (Resource Owner Password Credentials) which bypasses MFA.
    FOR LAB AND DEMO USE ONLY. Do NOT deploy in production environments.
.PARAMETER ConfigPath
    Path to agents.json configuration file.
.PARAMETER SkipPrerequisites
    Skip prerequisite checks (use if you already validated).
.PARAMETER Step
    Run only a specific step (0-10). Without -Step, the full deployment runs.
    Step 4 includes 4a/4b/4c. Step 6 includes 6a/6b/6c.
.PARAMETER DryRun
    Show what would be done without making changes.
.PARAMETER UseExistingUsers
    Skip user creation and instead pick existing Entra ID users interactively.
    Equivalent to setting features.userMode = "existing" in agents.json.
.PARAMETER RegisterProviders
    Ask the prerequisite checker to register missing Azure resource providers.
    Use this for new Azure subscriptions before first deployment.
.EXAMPLE
    .\Install-ClaudIA.ps1
    .\Install-ClaudIA.ps1 -UseExistingUsers
    .\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites
    .\Install-ClaudIA.ps1 -DryRun

    === WIZARD FLOW (10 steps, all idempotent) ===

    Step 0: PREREQUISITES
      Runs Test-Prerequisites.ps1 (13 checks: tools, providers, licenses, permissions).
      -> Skip with -SkipPrerequisites if you already validated.

    Step 1: CREATE OR SELECT AGENTS
      Mode 'create': Creates Entra ID users from agents.json, generates shared password.
      Mode 'existing': Launches interactive picker (Select-ExistingUsers.ps1).
      Mode 'prompt': Asks which mode at runtime.
      -> Customize via -UseExistingUsers switch or features.userMode in agents.json.

    Step 1b: PERSONA PROFILE PHOTOS
      Optional: uploads Images/Characters profile photos to Entra users.
      -> Calls tools/Set-EntraUserPhotos.ps1.

    Step 2: LICENSES + MFA EXCLUSION
      Assigns M365 E5 (all agents) + Copilot (Wave 2) licenses via Graph API.
      Creates grp-claudia-agent-mfa-exclusion security group and adds all agents.
      -> MANUAL: Exclude this group from your Conditional Access MFA policy.

    Step 3: REGISTER ENTRA APP
      Creates app-claudia-dataagent with 11 delegated scopes for ROPC.
      -> Calls modules/Register-AgentApp.ps1.

    Step 4: DEPLOY AZURE INFRASTRUCTURE
      Creates: Resource Group, Azure OpenAI (S0), Automation (Basic), and Key Vault access.
      ADX telemetry is provisioned with tools/Deploy-AdxTelemetry.ps1 after Step 4.
      -> Calls modules/Deploy-AzureInfra.ps1.

    Step 4a: M365 COLLABORATION
      Creates SharePoint site + Teams team + department channels + folders.
      Adds all agents as team members. Stores IDs in Automation variables.
      -> Calls modules/Provision-M365Collaboration.ps1.

    Step 4b: SENSITIVITY LABELS
      Creates 5 labels (General, Confidential, Conf-HR, Conf-Finance, Highly Confidential).
      Publishes label policy. Labels take 24-48h to propagate.
      -> Calls modules/Provision-SensitivityLabels.ps1.

    Step 4c: FABRIC PROVISIONING (conditional)
      Creates F2 capacity, workspace, and lakehouse for OneLake dual-write.
      Only runs if fabricEnabled=true in agents.json.
      -> Calls modules/Provision-Fabric.ps1.

    Step 5: STORE SECRETS + DEPLOY RUNBOOK
      Stores agent passwords and app secret in Key Vault, plus non-secret
      config/secret names as Automation variables.
      Uploads and publishes the runbook. Creates 3 daily schedules.
      -> Calls modules/Deploy-Runbook.ps1.

    Step 6: CONFIGURE PURVIEW (DLP + IRM)
      Creates 3 DSPM DLP policies. Prints IRM manual steps.
      -> Calls modules/Configure-DLP.ps1.

    Step 7: DEPLOY WORKBOOK
      Deploys ClaudIA Activity Monitor Azure workbook (8 KQL sections).
      -> Calls modules/Deploy-Workbook.ps1.

    Step 8: DEPLOY ACTIVITY STORY MAP
      Deploys an Azure Storage static website and Azure Function backed by ADX.
      -> Calls modules/Deploy-ActivityStoryMap.ps1.

    Step 9: BROWSERAGENT CLOUD AUTOMATION
      Optional: creates regional Playwright Workspaces and Container Apps Jobs.
      -> Calls tools/Deploy-BrowserAgentInfra.ps1 and tools/Deploy-BrowserAgentScheduledJobs.ps1.

    Step 10: MDCA CLOUD DISCOVERY CONNECTOR
      Optional: stores MDCA portal/token settings and validates Cloud Discovery API access.
      -> Calls tools/Deploy-MdcaCloudDiscoveryConnector.ps1.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipPrerequisites,
    [int]$Step = 0,
    [switch]$DryRun,
    [switch]$UseExistingUsers,
    [switch]$UseInstallationDefinitions,
    [switch]$RegisterProviders,
    [switch]$Auto,
    [string]$AgentPassword
)

$ErrorActionPreference = 'Stop'
# Capture the operator-supplied -ConfigPath (if any). The real resolution happens
# after modules\Common.ps1 is dot-sourced below, so per-tenant config files in
# config\tenants\ can be auto-selected. An explicit -ConfigPath always wins.
$script:ExplicitConfigPath = $ConfigPath

function Test-AARepositoryStructure {
    $requiredPaths = @(
        'modules\Common.ps1',
        'modules\Common.Core.ps1',
        'modules\Common.Config.ps1',
        'modules\Common.Azure.ps1',
        'modules\Deploy-AzureInfra.ps1',
        'modules\Deploy-Runbook.ps1',
        'modules\Invoke-AgentRunbook.ps1',
        'modules\steps',
        'modules\runbook',
        'prerequisites\Test-Prerequisites.ps1',
        'config\agents.json',
        'config\locales',
        'tools'
    )

    $missing = @()
    foreach ($relativePath in $requiredPaths) {
        $fullPath = Join-Path $PSScriptRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) { $missing += $relativePath }
    }

    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "[ERROR] ClaudIA repository structure is incomplete." -ForegroundColor Red
        Write-Host "        It looks like you may be running only Install-ClaudIA.ps1 or a partial download." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Missing required paths:" -ForegroundColor Yellow
        foreach ($item in $missing) { Write-Host "  - $item" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "Fix:" -ForegroundColor Cyan
        Write-Host "  1. Clone or download the full repository." -ForegroundColor Gray
        Write-Host "  2. Open PowerShell in the repository root, the folder that contains modules, config, tools, and Install-ClaudIA.ps1." -ForegroundColor Gray
        Write-Host "  3. Run:" -ForegroundColor Gray
        Write-Host "     Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File" -ForegroundColor White
        Write-Host "     .\Install-ClaudIA.ps1" -ForegroundColor White
        Write-Host ""
        Write-Host "Example:" -ForegroundColor Cyan
        Write-Host "  cd C:\MyDev\ClaudIA" -ForegroundColor White
        Write-Host "  .\Install-ClaudIA.ps1" -ForegroundColor White
        exit 1
    }
}

function Get-AABlockedPowerShellFiles {
    $blocked = @()
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Force -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '\\.git\\' } |
        ForEach-Object {
            try {
                $stream = Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
                if ($stream) { $blocked += $_ }
            } catch {
                # Some filesystems do not expose alternate data streams.
            }
        }
    return $blocked
}

function Invoke-AAUnblockProjectFiles {
    $blocked = @(Get-AABlockedPowerShellFiles)
    if ($blocked.Count -eq 0) { return }

    Write-Host ""
    Write-Host "[WARN] Windows marked $($blocked.Count) ClaudIA PowerShell script(s) as downloaded from the internet." -ForegroundColor Yellow
    Write-Host "       PowerShell may block unsigned helper scripts such as modules\Common.ps1." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "Recommended fix:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File" -ForegroundColor White
    Write-Host ""

    $choice = if ($Auto) { 'Y' } else { Read-Host "  Unblock all ClaudIA .ps1 files now? (Y/n)" }
    if ($choice -in @('n','N','no','NO')) {
        Write-Host "  Continuing without unblocking. If the next step fails with a digital signature error, run the command above." -ForegroundColor Yellow
        return
    }

    foreach ($file in $blocked) {
        try { Unblock-File -LiteralPath $file.FullName -ErrorAction Stop }
        catch { Write-Host "  [WARN] Could not unblock $($file.FullName): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Write-Host "  [OK] ClaudIA PowerShell files were unblocked." -ForegroundColor Green
}

Test-AARepositoryStructure
Invoke-AAUnblockProjectFiles

try {
    . (Join-Path $PSScriptRoot 'modules\Common.ps1')
} catch {
    Write-Host ""
    Write-Host "[ERROR] Could not load modules\Common.ps1." -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If this is a digital signature or execution policy error, run:" -ForegroundColor Cyan
    Write-Host "  Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File" -ForegroundColor White
    Write-Host ""
    Write-Host "Then run the installer again:" -ForegroundColor Cyan
    Write-Host "  .\Install-ClaudIA.ps1" -ForegroundColor White
    exit 1
}

# Resolve the config file now that Common.ps1 is available: an explicit
# -ConfigPath wins, otherwise auto-select a per-tenant file from config\tenants\
# (CLAUDIA_TENANT env var or the current az login domain), else fall back to the
# shared config\agents.json.
$ConfigPath = Resolve-AATenantConfigPath -RepoRoot $PSScriptRoot -ExplicitPath $script:ExplicitConfigPath

$script:AADeploymentResults = @()
$script:StepParameterSupplied = $PSBoundParameters.ContainsKey('Step')
$script:RunAllSteps = -not $script:StepParameterSupplied

function Test-AAInstallStep {
    param([Parameter(Mandatory)][string]$StepId)

    if ($script:RunAllSteps) { return $true }

    switch ($StepId) {
        '0' { return $Step -eq 0 }
        '1' { return $Step -eq 1 }
        '2' { return $Step -eq 2 }
        '3' { return $Step -eq 3 }
        '4' { return $Step -eq 4 }
        '4a' { return $Step -eq 4 }
        '4b' { return $Step -eq 4 }
        '4c' { return $Step -eq 4 }
        '5' { return $Step -eq 5 }
        '6a' { return $Step -eq 6 }
        '6b' { return $Step -eq 6 }
        '6c' { return $Step -eq 6 }
        '7' { return $Step -eq 7 }
        '8' { return $Step -eq 8 }
        '9' { return $Step -eq 9 }
        '10' { return $Step -eq 10 }
        default { return $false }
    }
}

function Format-AAAgentWaveSummary {
    param([object[]]$AgentList)

    $parts = @()
    $assignedCount = 0
    $waveGroups = @($AgentList | Where-Object { $_.wave } | Group-Object wave | Sort-Object { [int]$_.Name })
    foreach ($group in $waveGroups) {
        $parts += "$($group.Count) Wave $($group.Name)"
        $assignedCount += $group.Count
    }
    $unassigned = @($AgentList).Count - $assignedCount
    if ($unassigned -gt 0) { $parts += "$unassigned unassigned" }
    if ($parts.Count -eq 0) { $parts = @("$(@($AgentList).Count) unassigned") }
    $summary = "$(@($AgentList).Count) ($($parts -join ' + '))"
    return $summary
}

$logRoot = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logRoot)) { New-Item -ItemType Directory -Path $logRoot | Out-Null }
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLogPath = Join-Path $logRoot "Install-ClaudIA-$runStamp.log"
$installationDefinitionsPath = Join-Path $PSScriptRoot 'config\Installation_definitions.json'
Start-Transcript -Path $runLogPath -Append | Out-Null
Write-Host "  Log file: $runLogPath" -ForegroundColor Gray

# Pair the shared state file with the resolved tenant: archives the previous
# tenant's Installation_definitions.json and restores this tenant's. Prevents a
# run against tenant A from overwriting tenant B's deployment state (or a
# template-config run from wiping real state). Runs AFTER Start-Transcript so
# the switch messages (and any file-lock failure) land in the log.
Sync-AAInstallationDefinitionsWithTenant -RepoRoot $PSScriptRoot -ConfigPath $ConfigPath

# ============================================================================
# BANNER + DISCLAIMER
# ============================================================================
try { Clear-Host } catch {}
Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  ClaudIA - Lab Deployment Wizard" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  WARNING: This tool deploys autonomous agents that:" -ForegroundColor Yellow
Write-Host "    - Use ROPC (Resource Owner Password Credentials)" -ForegroundColor Yellow
Write-Host "    - Bypass MFA via Conditional Access exclusion" -ForegroundColor Yellow
Write-Host "    - Generate fictitious but realistic PII data" -ForegroundColor Yellow
Write-Host "    - Create files, emails, and Teams messages automatically" -ForegroundColor Yellow
Write-Host ""
Write-Host "  FOR LAB AND DEMO USE ONLY." -ForegroundColor Red
Write-Host "  Do NOT deploy in production environments." -ForegroundColor Red
Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

if (-not $DryRun) {
    $confirm = if ($Auto) { 'LAB' } else { Read-Host "  Type 'LAB' to confirm this is a lab environment" }
    if ($confirm -ne 'LAB') {
        Write-Host "  Aborted. Type 'LAB' to proceed." -ForegroundColor Red
        return
    }
}
Write-Host ""

# ============================================================================
# LOAD CONFIG
# ============================================================================
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config file not found: $ConfigPath" -ForegroundColor Red
    Write-Host "  Copy config/agents.json.example to config/agents.json and edit it." -ForegroundColor Yellow
    return
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Test-AAConfigNeedsSetup {
    param([Parameter(Mandatory)]$Config)

    $placeholderDomains = @('contoso.example', 'example.com', 'example.test')
    $placeholderGuids = @(
        '00000000-0000-0000-0000-000000000000',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333',
        '44444444-4444-4444-4444-444444444444'
    )

    $domain = [string]$Config.tenant.domain
    $tenantId = [string]$Config.tenant.tenantId
    $subscriptionId = [string]$Config.tenant.subscriptionId

    return (
        [string]::IsNullOrWhiteSpace($domain) -or
        $domain -match 'REPLACE_WITH' -or
        $placeholderDomains -contains $domain.ToLowerInvariant() -or
        [string]::IsNullOrWhiteSpace($subscriptionId) -or
        $subscriptionId -match 'REPLACE_WITH' -or
        $placeholderGuids -contains $subscriptionId -or
        $placeholderGuids -contains $tenantId
    )
}

$configNeedsSetup = Test-AAConfigNeedsSetup -Config $config
$freshDefinitions = ($script:RunAllSteps -and -not $SkipPrerequisites -and -not $UseInstallationDefinitions -and $configNeedsSetup)
$script:ForceConfigurationPrompt = $freshDefinitions

if ($UseInstallationDefinitions) {
    if (-not (Test-Path $installationDefinitionsPath)) {
        Write-Host "[ERROR] Installation definitions not found: $installationDefinitionsPath" -ForegroundColor Red
        Write-Host "  Run without -UseInstallationDefinitions to collect fresh values first." -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        return
    }

    $savedDefinitions = Get-Content $installationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Host "  Loading installation definitions from $installationDefinitionsPath" -ForegroundColor Cyan

    if ($savedDefinitions.tenant) {
        foreach ($prop in @('domain','tenantId','subscriptionId','location','country')) {
            if ($savedDefinitions.tenant.$prop) {
                $config.tenant.PSObject.Properties[$prop].Value = $savedDefinitions.tenant.$prop
            }
        }
    }
    if ($savedDefinitions.infrastructure) {
                foreach ($prop in @('resourceGroup','automationAccountName','openAiAccountName','openAiModel','openAiModelVersion','openAiImageModel','openAiImageModelVersion','openAiTpm','fabricEnabled','keyVaultName')) {
            if ($savedDefinitions.infrastructure.PSObject.Properties[$prop]) {
                if ($config.infrastructure.PSObject.Properties[$prop]) {
                    $config.infrastructure.PSObject.Properties[$prop].Value = $savedDefinitions.infrastructure.$prop
                } else {
                    $config.infrastructure | Add-Member -NotePropertyName $prop -NotePropertyValue $savedDefinitions.infrastructure.$prop -Force
                }
            }
        }
    }
    if ($savedDefinitions.adx) {
        if ($config.PSObject.Properties['adx']) {
            $config.adx = $savedDefinitions.adx
        } else {
            $config | Add-Member -NotePropertyName adx -NotePropertyValue $savedDefinitions.adx -Force
        }
    }
    if ($savedDefinitions.agents -and @($savedDefinitions.agents).Count -gt 0) {
        $config.agents = @($savedDefinitions.agents | ForEach-Object {
            [PSCustomObject]@{
                sam = $_.sam
                userPrincipalName = $_.userPrincipalName
                displayName = $_.displayName
                department = $_.department
                jobTitle = $_.jobTitle
                wave = $_.wave
                workload = $_.workload
                copilotLicense = $_.copilotLicense
                existingUser = $_.existingUser
                workingHours = if ($_.workingHours) { $_.workingHours } else { @{ start = 8; end = 17 } }
                filesPerDay = if ($_.filesPerDay) { $_.filesPerDay } else { @(4, 7) }
                emailsPerDay = if ($_.emailsPerDay) { $_.emailsPerDay } else { @(2, 4) }
                style = if ($_.style) { $_.style } else { "professional, context-appropriate" }
                topics = if ($_.topics) { $_.topics } else { @() }
            }
        })
    }
}

Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
    -RunLogPath $runLogPath -RunStamp $runStamp -Fresh:$freshDefinitions

if (($freshDefinitions -or (Test-AAInstallStep '0')) -and -not $SkipPrerequisites) {
    Write-Host "=== Step 0: Resetting active connections ===" -ForegroundColor Cyan
    Write-Host "  Closing PowerShell cloud sessions before collecting installation data..." -ForegroundColor Gray
    $connectionReset = Close-AAConnections
    Set-AAInstallationDefinition -Path $installationDefinitionsPath -Section 'sessionReset' -Value $connectionReset
    Write-Host "  [OK] Active PowerShell sessions reset. Azure CLI sign-in will be validated during tenant setup." -ForegroundColor Green
    Write-Host "  Installation definitions: $installationDefinitionsPath" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================================
# INTERACTIVE SETUP - prompt for any missing or placeholder values
# ============================================================================
# Detects REPLACE_WITH placeholders and prompts the admin interactively.
# Entered values are saved back to agents.json so they persist across runs.
$configChanged = $false

function Read-ConfigValue {
    param([string]$Label, [string]$Current, [string]$Default, [string]$Hint)
    $isPlaceholder = $Current -match 'REPLACE_WITH'
    if ($isPlaceholder -or $script:ForceConfigurationPrompt) {
        $effectiveDefault = if ($Default) { $Default } else { $Current }
        $promptDefault = if ($effectiveDefault) { " [$effectiveDefault]" } else { '' }
        if ($Hint) { Write-Host "    $Hint" -ForegroundColor DarkGray }
        $input = Read-Host "    $Label$promptDefault"
        if (-not $input -and $effectiveDefault) { $input = $effectiveDefault }
        if (-not $input) {
            Write-Host "    [ERROR] Value required." -ForegroundColor Red
            return $null
        }
        return $input
    }
    return $Current
}

function Set-AAConfigProperty {
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

function Test-AAGuid {
    param([string]$Value)
    if (-not $Value) { return $false }
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsed)
}

function Test-AAResourceGroupName {
    param([string]$Value)
    if (-not $Value) { return $false }
    if (Test-AAGuid -Value $Value) { return $false }
    if ($Value.Length -gt 90) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9_\-\.\(\)]+$') { return $false }
    if ($Value.EndsWith('.')) { return $false }
    return $true
}

function Read-AAResourceGroupName {
    param([string]$Current, [string]$SubscriptionId)

    while ($true) {
        Write-Host "    Resource group [$Current]: " -NoNewline
        $value = Read-Host
        if (-not $value) { $value = $Current }

        if ($value -eq $SubscriptionId -or (Test-AAGuid -Value $value)) {
            Write-Host "    [ERROR] Resource group must be a name like 'rg-claudia-lab', not a subscription ID." -ForegroundColor Red
            continue
        }

        if (-not (Test-AAResourceGroupName -Value $value)) {
            Write-Host "    [ERROR] Resource group names can use letters, numbers, underscores, hyphens, periods, and parentheses; max 90 characters; cannot end with a period." -ForegroundColor Red
            continue
        }

        return $value
    }
}

function Show-AAPrerequisiteGuidance {
    param($PrerequisiteResult)

    $failed = @($PrerequisiteResult.Results | Where-Object { $_.Status -eq 'Fail' })
    if ($failed.Count -eq 0) { return }

    $failedNames = @($failed | ForEach-Object { [string]$_.Name })
    Write-Host ""
    Write-Host "  What blocked the deployment:" -ForegroundColor Yellow

    $providerFailures = @($failed | Where-Object { $_.Category -eq 'Azure Resource Providers' })
    if ($providerFailures.Count -gt 0) {
        Write-Host "    - Azure resource providers are not registered in this new subscription." -ForegroundColor Gray
        Write-Host "      Resource providers are registered at subscription scope; a resource group is not required yet." -ForegroundColor Gray
        Write-Host "      Fix: let ClaudIA register them now, rerun with .\Install-ClaudIA.ps1 -RegisterProviders, or run the az provider register commands shown above." -ForegroundColor DarkYellow
    }

    if ($failedNames -contains 'Deploying user has admin directory role') {
        Write-Host "    - The current Azure CLI account can access the Azure subscription but is not a Microsoft 365/Entra deployment admin." -ForegroundColor Gray
        Write-Host "      ClaudIA Step 1 cannot create users, Step 2 cannot assign licenses, and Step 3 cannot grant app consent without tenant admin rights." -ForegroundColor Gray
        Write-Host "      Easiest fix: use one deployment account that has Azure Owner/Contributor plus Global Administrator or Privileged Role Administrator in the target tenant." -ForegroundColor DarkYellow
    }

    if ($failedNames -contains 'Azure CLI logged in') {
        Write-Host "    - Azure CLI is not logged in to a usable account." -ForegroundColor Gray
        Write-Host "      Fix: az logout; az login --tenant <tenant-domain>; az account list -o table." -ForegroundColor DarkYellow
    }
}

function Test-AAOnlyProviderFailures {
    param($PrerequisiteResult)

    $failed = @($PrerequisiteResult.Results | Where-Object { $_.Status -eq 'Fail' })
    if ($failed.Count -eq 0) { return $false }
    $nonProviderFailures = @($failed | Where-Object { $_.Category -ne 'Azure Resource Providers' })
    return ($nonProviderFailures.Count -eq 0)
}

function Test-AAAutomationAccountAvailable {
    param([Parameter(Mandatory)]$Config)

    $aaName = [string]$Config.infrastructure.automationAccountName
    $rg = [string]$Config.infrastructure.resourceGroup
    $subscriptionId = [string]$Config.tenant.subscriptionId
    if (-not $aaName -or -not $rg) { return $false }

    $aa = az automation account show --only-show-errors -n $aaName -g $rg --query id -o tsv 2>$null
    if ($aa) { return $true }

    $aaOther = az automation account list --only-show-errors --query "[?name=='$aaName'].id | [0]" -o tsv 2>$null
    if ($aaOther) { return $true }

    if ($subscriptionId) {
        $escapedRg = [System.Uri]::EscapeDataString($rg)
        $escapedName = [System.Uri]::EscapeDataString($aaName)
        $url = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$escapedRg/providers/Microsoft.Automation/automationAccounts/${escapedName}?api-version=2023-11-01"
        $restId = az rest --method get --url $url --query id -o tsv 2>$null
        if ($restId) { return $true }
    }

    return $false
}

function Update-AAAgentUpnDomains {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Domain
    )

    if (-not $Config.agents) { return 0 }
    $updated = 0
    foreach ($agent in @($Config.agents)) {
        if (-not $agent.sam) { continue }
        $targetUpn = "$($agent.sam)@$Domain"
        foreach ($propertyName in @('userPrincipalName','upn')) {
            if (-not $agent.PSObject.Properties[$propertyName]) { continue }
            $currentUpn = [string]$agent.$propertyName
            if (-not $currentUpn) { continue }
            $currentDomain = ($currentUpn -split '@')[-1]
            if ($currentDomain -in @('contoso.example','example.com','example.test') -or $currentDomain -ne $Domain) {
                Set-AAConfigProperty -Object $agent -Name $propertyName -Value $targetUpn
                $updated++
            }
        }
    }
    return $updated
}

function Set-AACopilotQueriesFeature {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][bool]$Enabled
    )

    if (-not $Config.PSObject.Properties['features'] -or -not $Config.features) {
        $Config | Add-Member -NotePropertyName features -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    Set-AAConfigProperty -Object $Config.features -Name copilotQueries -Value $Enabled
}

function Sync-AABrowserAgentConfig {
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.PSObject.Properties['browserAgents'] -or -not $Config.browserAgents) { return }
    Set-AAConfigProperty -Object $Config.browserAgents -Name subscriptionId -Value $Config.tenant.subscriptionId
    Set-AAConfigProperty -Object $Config.browserAgents -Name resourceGroup -Value $Config.infrastructure.resourceGroup
    if (-not $Config.browserAgents.location -or $Config.browserAgents.location -match 'REPLACE_WITH') {
        Set-AAConfigProperty -Object $Config.browserAgents -Name location -Value 'eastus'
    }
}

function Set-AABrowserWorkspaceResult {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$WorkspaceConfig,
        [Parameter(Mandatory)]$Result
    )

    if (-not $Result.WorkspaceId) { return }
    Set-AAConfigProperty -Object $WorkspaceConfig -Name workspaceId -Value ([string]$Result.WorkspaceId)
    Set-AAConfigProperty -Object $WorkspaceConfig -Name dataplaneUri -Value ([string]$Result.DataplaneUri)
    Set-AAConfigProperty -Object $WorkspaceConfig -Name playwrightServiceUrl -Value ([string]$Result.PlaywrightServiceUrl)

    if ([string]$WorkspaceConfig.key -eq 'americas') {
        Set-AAConfigProperty -Object $Config.browserAgents -Name workspaceName -Value ([string]$Result.WorkspaceName)
        Set-AAConfigProperty -Object $Config.browserAgents -Name workspaceId -Value ([string]$Result.WorkspaceId)
        Set-AAConfigProperty -Object $Config.browserAgents -Name dataplaneUri -Value ([string]$Result.DataplaneUri)
        Set-AAConfigProperty -Object $Config.browserAgents -Name playwrightServiceUrl -Value ([string]$Result.PlaywrightServiceUrl)
    }
}

function New-AAShortSuffix {
    param([string]$Seed)

    $randomPart = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Seed-$randomPart")
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
}

function Get-AANameBase {
    param($Config)

    $domainPart = if ($Config.tenant.domain) { ($Config.tenant.domain -split '\.')[0] } else { 'agents' }
    $base = ($domainPart -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $base) { $base = 'agents' }
    if ($base.Length -gt 12) { $base = $base.Substring(0, 12) }
    return $base
}

function New-AADefaultOpenAiName {
    param($Config)

    $base = Get-AANameBase -Config $Config
    $suffix = New-AAShortSuffix -Seed "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-openai"
    return "oai-$base-$suffix"
}

function New-AADefaultKeyVaultName {
    param($Config)

    $base = Get-AANameBase -Config $Config
    if ($base.Length -gt 10) { $base = $base.Substring(0, 10) }
    $suffix = New-AAShortSuffix -Seed "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-kv"
    return "kv$base$suffix"
}

function Invoke-AAAzureCliLogin {
    param(
        [string]$TenantHint,
        [switch]$ForceLogout
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "    [WARN] Azure CLI is not installed or not in PATH." -ForegroundColor Yellow
        Write-Host "           Install it first: winget install Microsoft.AzureCLI" -ForegroundColor DarkYellow
        return $null
    }

    $tenantArg = @()
    if ($TenantHint -and $TenantHint -notmatch 'REPLACE_WITH') {
        $tenantArg = @('--tenant', $TenantHint)
    }

    Write-Host ""
    if ($ForceLogout) {
        Write-Host "    Clearing cached Azure CLI sessions before target-tenant sign-in..." -ForegroundColor Cyan
        az logout 2>$null | Out-Null
    }
    Write-Host "    Azure CLI needs a sign-in for the target demo tenant." -ForegroundColor Cyan
    Write-Host "    A device-code login will open. Use a target-tenant admin account when possible." -ForegroundColor Gray
    Write-Host "    External users must already be invited into this tenant and assigned Azure RBAC on the subscription." -ForegroundColor Gray
    & az login @tenantArg --use-device-code | Out-Null

    $activeTenantId = az account show --query tenantId -o tsv 2>$null
    if ($activeTenantId) {
        $script:AATargetTenantId = [string]$activeTenantId
        Write-Host "    [OK] Azure CLI active tenant: $script:AATargetTenantId" -ForegroundColor Green
    } else {
        Write-Host "    [WARN] Could not determine Azure CLI active tenant. Subscription filtering may be limited." -ForegroundColor Yellow
        Write-Host "           If you selected an external account, add it as a guest/member in Entra ID, accept the invitation, and assign Owner or Contributor on the Azure subscription." -ForegroundColor DarkYellow
    }
    return $script:AATargetTenantId
}

function Get-AACurrentAzureCliAccount {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $acctJson = az account show -o json 2>$null
    if (-not $acctJson) { return $null }
    try { return ($acctJson | ConvertFrom-Json) } catch { return $null }
}

function Test-AACurrentUserHasTenantAdminRole {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $false }
    $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $token) { return $false }
    $headers = @{ Authorization = "Bearer $token" }
    try {
        $roles = (Invoke-RestMethod 'https://graph.microsoft.com/v1.0/me/memberOf' -Headers $headers -ErrorAction Stop).value
        $adminRoles = @($roles | Where-Object {
            $_.'@odata.type' -eq '#microsoft.graph.directoryRole' -and
            $_.displayName -match 'Global Administrator|Privileged Role Administrator'
        })
        return ($adminRoles.Count -gt 0)
    } catch {
        return $false
    }
}

function Invoke-AAM365Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not $script:AAM365AzConfigDir) { return $null }
    $oldConfigDir = $env:AZURE_CONFIG_DIR
    $env:AZURE_CONFIG_DIR = $script:AAM365AzConfigDir
    try {
        & az @Arguments
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

function Get-AAGraphAccessToken {
    if ($script:AAM365AzConfigDir) {
        $token = Invoke-AAM365Az -Arguments @('account','get-access-token','--resource','https://graph.microsoft.com','--query','accessToken','-o','tsv') 2>$null
        if ($token) { return [string]$token }
    }
    return (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null)
}

function Test-AAM365AdminProfileHasTenantAdminRole {
    $token = Get-AAGraphAccessToken
    if (-not $token) { return $false }
    $headers = @{ Authorization = "Bearer $token" }
    try {
        $roles = (Invoke-RestMethod 'https://graph.microsoft.com/v1.0/me/memberOf' -Headers $headers -ErrorAction Stop).value
        $adminRoles = @($roles | Where-Object {
            $_.'@odata.type' -eq '#microsoft.graph.directoryRole' -and
            $_.displayName -match 'Global Administrator|Privileged Role Administrator'
        })
        return ($adminRoles.Count -gt 0)
    } catch {
        return $false
    }
}

function Initialize-AAM365AdminProfileFromDisk {
    $candidate = Join-Path $PSScriptRoot '.claudia\az-m365-admin'
    if (-not (Test-Path -LiteralPath $candidate)) { return $false }

    $script:AAM365AzConfigDir = $candidate
    $acctJson = Invoke-AAM365Az -Arguments @('account','show','-o','json') 2>$null
    if (-not $acctJson) {
        $script:AAM365AzConfigDir = $null
        return $false
    }

    $acct = $null
    try { $acct = $acctJson | ConvertFrom-Json } catch {}
    if ($acct -and $acct.user) {
        Write-Host "  Reusing Microsoft 365 admin profile: $($acct.user.name)" -ForegroundColor Gray
    }
    return $true
}

function Initialize-AAM365AdminSignIn {
    param([string]$TenantHint)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "    [WARN] Azure CLI is not installed or not in PATH." -ForegroundColor Yellow
        return $false
    }

    $script:AAM365AzConfigDir = Join-Path $PSScriptRoot '.claudia\az-m365-admin'
    if (-not (Test-Path -LiteralPath $script:AAM365AzConfigDir)) {
        New-Item -ItemType Directory -Path $script:AAM365AzConfigDir -Force | Out-Null
    }

    Write-Host ""
    Write-Host "    Starting separate Microsoft 365 admin sign-in..." -ForegroundColor Cyan
    Write-Host "    This uses an isolated Azure CLI profile under .claudia, so your Azure subscription sign-in is preserved." -ForegroundColor Gray
    $oldConfigDir = $env:AZURE_CONFIG_DIR
    $env:AZURE_CONFIG_DIR = $script:AAM365AzConfigDir
    try {
        az logout 2>$null | Out-Null
        & az login --tenant $TenantHint --allow-no-subscriptions --use-device-code | Out-Null
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }

    $acctJson = Invoke-AAM365Az -Arguments @('account','show','-o','json') 2>$null
    $acct = $null
    if ($acctJson) { try { $acct = $acctJson | ConvertFrom-Json } catch {} }
    if ($acct -and $acct.user) {
        Write-Host "    [OK] Microsoft 365 admin profile signed in as: $($acct.user.name)" -ForegroundColor Green
    }

    if (Test-AAM365AdminProfileHasTenantAdminRole) {
        Write-Host "    [OK] This account has a tenant admin role for Microsoft 365/Entra setup." -ForegroundColor Green
        return $true
    }

    Write-Host "    [WARN] The separate Microsoft 365 account still does not appear to have Global Administrator or Privileged Role Administrator." -ForegroundColor Yellow
    return $false
}

function Select-AASubscription {
    param([string]$Current)

    $accountsJson = az account list --query "[].{name:name,id:id,isDefault:isDefault,tenantId:tenantId}" -o json 2>$null
    $accounts = @()
    if ($accountsJson) {
        try { $accounts = @($accountsJson | ConvertFrom-Json) } catch { $accounts = @() }
    }

    if ($script:AATargetTenantId) {
        $tenantAccounts = @($accounts | Where-Object { $_.tenantId -eq $script:AATargetTenantId })
        if ($tenantAccounts.Count -gt 0) {
            $accounts = $tenantAccounts
        } elseif ($accounts.Count -gt 0) {
            Write-Host "    [WARN] Azure CLI has subscriptions cached, but none match target tenant $script:AATargetTenantId." -ForegroundColor Yellow
            Write-Host "           Sign in again with an account that can access the target tenant subscription." -ForegroundColor DarkYellow
            $accounts = @()
        }
    }

    if ($accounts.Count -eq 0) {
        Write-Host "    [WARN] Azure CLI has no visible subscriptions." -ForegroundColor Yellow
        $loginChoice = if ($Auto) { 'Y' } else { Read-Host "    Sign in to Azure CLI now? (Y/n)" }
        if ($loginChoice -notin @('n','N','no','NO')) {
            Invoke-AAAzureCliLogin -TenantHint $config.tenant.domain -ForceLogout | Out-Null
            $accountsJson = az account list --query "[].{name:name,id:id,isDefault:isDefault,tenantId:tenantId}" -o json 2>$null
            if ($accountsJson) {
                try { $accounts = @($accountsJson | ConvertFrom-Json) } catch { $accounts = @() }
            }
            if ($script:AATargetTenantId) {
                $accounts = @($accounts | Where-Object { $_.tenantId -eq $script:AATargetTenantId })
            }
        }
    }

    if ($accounts.Count -eq 0) {
        Write-Host "    [WARN] Azure CLI still has no visible subscriptions." -ForegroundColor Yellow
        Write-Host "           The signed-in account must exist in the target tenant and have Azure RBAC on the subscription." -ForegroundColor DarkYellow
        Write-Host "           Recommended fix: invite the account to the tenant, accept the invitation, assign Owner or Contributor, then run the installer again." -ForegroundColor DarkYellow
        $manualChoice = if ($Auto) { 'N' } else { Read-Host "    Type a subscription ID manually anyway? Step 4 will fail without access. (y/N)" }
        if ($manualChoice -notin @('y','Y','yes','YES')) { return $null }
        $manualSub = Read-ConfigValue -Label "Azure subscription ID" -Current $Current -Hint "e.g. 00000000-0000-0000-0000-000000000000"
        if ($manualSub -and -not (Test-AAGuid -Value $manualSub)) {
            Write-Host "    [ERROR] Subscription ID must be a GUID." -ForegroundColor Red
            return $null
        }
        return $manualSub
    }

    Write-Host "    Available Azure subscriptions:" -ForegroundColor Gray
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $marker = if ($accounts[$i].id -eq $Current) { 'current' } elseif ($accounts[$i].isDefault) { 'default' } else { '' }
        $suffix = if ($marker) { " [$marker]" } else { '' }
        Write-Host "      [$($i + 1)] $($accounts[$i].name) - $($accounts[$i].id) (tenant $($accounts[$i].tenantId))$suffix" -ForegroundColor Gray
    }

    $promptDefault = if ($Current) { " [$Current]" } else { '' }
    $selection = Read-Host "    Azure subscription (number or ID)$promptDefault"
    if (-not $selection -and $Current) { return $Current }

    if ($selection -match '^\d+$') {
        $idx = [int]$selection
        if ($idx -ge 1 -and $idx -le $accounts.Count) { return [string]$accounts[$idx - 1].id }
    }

    $match = $accounts | Where-Object { $_.id -eq $selection -or $_.name -eq $selection } | Select-Object -First 1
    if ($match) { return [string]$match.id }

    if (-not (Test-AAGuid -Value $selection)) {
        Write-Host "    [ERROR] Enter a number from the list, an exact subscription name from the list, or a subscription GUID." -ForegroundColor Red
        return $null
    }
    Write-Host "    [WARN] Subscription '$selection' is not in az account list. It will be saved, but Step 4 will fail unless this account can access it." -ForegroundColor Yellow
    return $selection
}

if (-not $script:AAM365AzConfigDir) {
    Initialize-AAM365AdminProfileFromDisk | Out-Null
}

# Check if interactive setup is needed
$needsSetup = Test-AAConfigNeedsSetup -Config $config

if (($needsSetup -or $script:ForceConfigurationPrompt) -and -not $DryRun -and -not $Auto) {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  INSTALLATION DEFINITIONS - Configure your lab environment" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    if ($script:ForceConfigurationPrompt) {
        Write-Host "  Fresh installation requested. All installation values will be collected again." -ForegroundColor Yellow
    } else {
        Write-Host "  agents.json has placeholder values. Let us set them up." -ForegroundColor Yellow
    }
    Write-Host "  Press Enter to accept [default] values." -ForegroundColor Gray
    Write-Host ""

    # --- TENANT ---
    Write-Host "  --- Tenant ---" -ForegroundColor White
    $newDomain = Read-ConfigValue -Label "Tenant domain" -Current $config.tenant.domain `
        -Hint "e.g. contoso.onmicrosoft.com"
    if (-not $newDomain) { return }
    if ($newDomain -ne $config.tenant.domain) { $config.tenant.domain = $newDomain; $configChanged = $true }
    $updatedAgentUpns = Update-AAAgentUpnDomains -Config $config -Domain $config.tenant.domain
    if ($updatedAgentUpns -gt 0) {
        Write-Host "    [OK] Updated $updatedAgentUpns agent UPN value(s) to use $($config.tenant.domain)." -ForegroundColor Green
        $configChanged = $true
    }

    Write-Host ""
    Write-Host "  --- Azure CLI Sign-In ---" -ForegroundColor White
    Write-Host "    The subscription list must come from the tenant you just entered: $($config.tenant.domain)" -ForegroundColor Gray
    Write-Host "    Cached Azure CLI sessions from other tenants can show unrelated subscriptions." -ForegroundColor Gray
    $freshAzLogin = Read-Host "    Sign out from cached Azure CLI sessions and sign in to this tenant now? (Y/n)"
    if ($freshAzLogin -notin @('n','N','no','NO')) {
        $tenantIdFromLogin = Invoke-AAAzureCliLogin -TenantHint $config.tenant.domain -ForceLogout
        if ($tenantIdFromLogin) {
            Set-AAConfigProperty -Object $config.tenant -Name tenantId -Value $tenantIdFromLogin
            $configChanged = $true
        }
    } else {
        Write-Host "    [WARN] Continuing with current Azure CLI cache. Verify subscription tenant IDs carefully." -ForegroundColor Yellow
    }

    $newSubId = Select-AASubscription -Current $config.tenant.subscriptionId
    if (-not $newSubId) { return }
    if ($newSubId -ne $config.tenant.subscriptionId) {
        Write-Host ""
        Write-Host "  [INFO] Subscription changed - clearing persisted globally-unique resource names" -ForegroundColor Yellow
        Write-Host "         (Azure OpenAI / Key Vault / Storage / Function App / ADX) so the installer" -ForegroundColor DarkGray
        Write-Host "         can regenerate fresh deterministic names for the new subscription." -ForegroundColor DarkGray
        # Persist current state first so Reset-UniqueNames sees the OLD configured sub vs the NEW active az sub.
        Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 30)
        & (Join-Path $PSScriptRoot 'tools\Reset-UniqueNames.ps1') -ConfigPath $ConfigPath -InstallationDefinitionsPath $installationDefinitionsPath -Force | Out-Host
        # Reload cleared state, then apply new sub.
        $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $config.tenant.subscriptionId = $newSubId
        $configChanged = $true
    }
    Sync-AABrowserAgentConfig -Config $config

    $activeAccount = Get-AACurrentAzureCliAccount
    if ($activeAccount -and $activeAccount.user) {
        Write-Host ""
        Write-Host "  --- Deployment Account Check ---" -ForegroundColor White
        Write-Host "    Signed in as: $($activeAccount.user.name)" -ForegroundColor Gray
        Write-Host "    ClaudIA's easiest setup uses one account with both Azure RBAC and Microsoft 365/Entra admin rights." -ForegroundColor Gray
        if (Test-AACurrentUserHasTenantAdminRole) {
            Write-Host "    [OK] This account has a tenant admin role for user/app setup." -ForegroundColor Green
        } else {
            Write-Host "    [WARN] This account does not appear to have Global Administrator or Privileged Role Administrator." -ForegroundColor Yellow
            Write-Host "           Step 1 user creation, Step 2 license assignment, and Step 3 app consent will be blocked until a tenant admin account is used or this account is granted the role." -ForegroundColor DarkYellow
            $separateM365 = if ($Auto) { 'N' } else { Read-Host "    Sign in with a separate Microsoft 365/Entra admin account now? (Y/n)" }
            if ($separateM365 -notin @('n','N','no','NO')) {
                Initialize-AAM365AdminSignIn -TenantHint $config.tenant.domain | Out-Null
            }
        }
    }

    Write-Host "    Location [$($config.tenant.location)]: " -NoNewline
    $newLoc = Read-Host
    if ($newLoc -and $newLoc -ne $config.tenant.location) { $config.tenant.location = $newLoc; $configChanged = $true }

    # --- GEOGRAPHIC CONTENT ---
    Write-Host ""
    Write-Host "  --- Geographic Content (PII patterns + personas) ---" -ForegroundColor White
    Write-Host "    Available locales:" -ForegroundColor Gray
    $localeDir = Join-Path $PSScriptRoot 'config\locales'
    if (Test-Path $localeDir) {
        Get-ChildItem $localeDir -Filter '*.json' | ForEach-Object {
            $l = Get-Content $_.FullName -Raw | ConvertFrom-Json
            Write-Host "      [$($l.country)] $($l.language) - $($l.companyName)" -ForegroundColor Gray
        }
    } else {
        Write-Host "    [WARN] No locales directory found at config/locales/" -ForegroundColor Yellow
    }
    $currentCountry = if ($config.tenant.country) { $config.tenant.country } else { 'US' }
    Write-Host "    Country [$currentCountry]: " -NoNewline
    $newCountry = Read-Host
    if ($newCountry) {
        $newCountry = $newCountry.Trim().ToUpper()
        if ($newCountry -eq 'GB') { $newCountry = 'UK' }  # ISO alias for the UK locale
        $localePath = Join-Path $localeDir "$newCountry.json"
        if (Test-Path $localePath) {
            if ($config.tenant.country -ne $newCountry) {
                $config.tenant.country = $newCountry
                $configChanged = $true
            }
            $locale = Get-Content $localePath -Raw | ConvertFrom-Json
            if ($locale.personas) {
                # Deep-clone the default agent template and overlay locale personas
                $defaultAgents = $config.agents
                $newAgents = @()
                for ($pi = 0; $pi -lt $locale.personas.Count; $pi++) {
                    $p = $locale.personas[$pi]
                    # Find matching template by index (preserves wave, workload, copilotLicense, etc.)
                    $template = if ($pi -lt $defaultAgents.Count) { $defaultAgents[$pi] } else { $defaultAgents[0] }
                    # Deep clone via JSON round-trip (safe for nested objects)
                    $clone = $template | ConvertTo-Json -Depth 5 | ConvertFrom-Json
                    $clone.sam = $p.sam
                    $clone.displayName = $p.displayName
                    $clone.department = $p.department
                    $clone.jobTitle = $p.jobTitle
                    $newAgents += $clone
                }
                $config.agents = $newAgents
                Write-Host "    Loaded $($newAgents.Count) personas from $newCountry locale" -ForegroundColor Green
            }
        } else {
            $availableLocales = (Get-ChildItem $localeDir -Filter '*.json' | ForEach-Object { $_.BaseName }) -join ', '
            Write-Host "    [WARN] No locale for '$newCountry'. Available: $availableLocales" -ForegroundColor Yellow
        }
    }

    # --- INFRASTRUCTURE ---
    Write-Host ""
    Write-Host "  --- Azure Resources (press Enter to keep defaults) ---" -ForegroundColor White
    Write-Host "  A new Azure subscription does not need an existing resource group." -ForegroundColor Gray
    Write-Host "  If the resource group below does not exist, ClaudIA will create it in Step 4." -ForegroundColor Gray

    $newResourceGroup = Read-AAResourceGroupName -Current $config.infrastructure.resourceGroup -SubscriptionId $config.tenant.subscriptionId
    if ($newResourceGroup -and $newResourceGroup -ne $config.infrastructure.resourceGroup) {
        Set-AAConfigProperty -Object $config.infrastructure -Name resourceGroup -Value $newResourceGroup
        Sync-AABrowserAgentConfig -Config $config
        $configChanged = $true
    }

    Write-Host "    Automation account [$($config.infrastructure.automationAccountName)]: " -NoNewline
    $newAutomationAccount = Read-Host
    if ($newAutomationAccount -and $newAutomationAccount -ne $config.infrastructure.automationAccountName) {
        Set-AAConfigProperty -Object $config.infrastructure -Name automationAccountName -Value $newAutomationAccount
        $configChanged = $true
    }

    if ($script:ForceConfigurationPrompt) {
        Set-AAConfigProperty -Object $config.infrastructure -Name openAiAccountName -Value (New-AADefaultOpenAiName -Config $config)
        Set-AAConfigProperty -Object $config.infrastructure -Name keyVaultName -Value (New-AADefaultKeyVaultName -Config $config)
        if (-not $config.infrastructure.openAiImageModel) {
            Set-AAConfigProperty -Object $config.infrastructure -Name openAiImageModel -Value 'gpt-image-1'
        }
        $configChanged = $true
    }

    $infraFields = @(
        @{ Key='keyVaultName';          Label='Key Vault';            Default=(Get-KeyVaultName -Config $config) },
        @{ Key='openAiAccountName';    Label='Azure OpenAI account';  Default=$config.infrastructure.openAiAccountName },
        @{ Key='openAiModel';          Label='OpenAI model';          Default=$config.infrastructure.openAiModel },
        @{ Key='openAiModelVersion';   Label='OpenAI model version';  Default=$config.infrastructure.openAiModelVersion },
        @{ Key='openAiImageModel';     Label='OpenAI image model';    Default=$config.infrastructure.openAiImageModel },
        @{ Key='openAiImageModelVersion'; Label='OpenAI image model version'; Default=$config.infrastructure.openAiImageModelVersion }
    )

    foreach ($field in $infraFields) {
        Write-Host "    $($field.Label) [$($field.Default)]: " -NoNewline
        $val = Read-Host
        if ($val -and $val -ne $field.Default) {
            Set-AAConfigProperty -Object $config.infrastructure -Name $field.Key -Value $val
            $configChanged = $true
        }
    }

    Write-Host "    Fabric enabled [$($config.infrastructure.fabricEnabled)]: " -NoNewline
    $fabVal = Read-Host
    if ($fabVal -in @('true','false')) {
        $config.infrastructure.fabricEnabled = ($fabVal -eq 'true')
        $configChanged = $true
    }

    # --- OPENAI SCALING ---
    Write-Host ""
    Write-Host "  --- Azure OpenAI Scaling ---" -ForegroundColor White
    Write-Host "    TPM (Tokens Per Minute) capacity:" -ForegroundColor Gray
    Write-Host "      10  = Light  (1 run/day, short content)" -ForegroundColor Gray
    Write-Host "      30  = Standard (3 runs/day, realistic content)" -ForegroundColor Gray
    Write-Host "      60  = Intensive (cross-dept, large files)" -ForegroundColor Gray
    Write-Host "    OpenAI TPM [$($config.infrastructure.openAiTpm)]: " -NoNewline
    $tpmVal = Read-Host
    if ($tpmVal -match '^\d+$') {
        $config.infrastructure.openAiTpm = [int]$tpmVal
        $configChanged = $true
    }

    Write-Host "    Image model (optional; Step 4 validates regional availability, Enter to skip) [$($config.infrastructure.openAiImageModel)]: " -NoNewline
    $imgVal = Read-Host
    if ($imgVal) {
        $config.infrastructure.openAiImageModel = $imgVal
        $configChanged = $true
    }

    # --- SAVE ---
    if ($configChanged -or $script:ForceConfigurationPrompt) {
        Write-Host ""
        Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 5)
        Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
            -RunLogPath $runLogPath -RunStamp $runStamp
        Write-Host "  Configuration saved to $ConfigPath" -ForegroundColor Green
        Write-Host "  Installation definitions updated at $installationDefinitionsPath" -ForegroundColor Green
    }
    Write-Host ""
} elseif ($needsSetup -and $Auto) {
    Write-Host "  [ERROR] -Auto requires agents.json to be pre-configured (no REPLACE_WITH placeholders)." -ForegroundColor Red
    Write-Host "  Edit config/agents.json first, then re-run with -Auto." -ForegroundColor Yellow
    return
} elseif ($needsSetup -and $DryRun) {
    Write-Host "  [DRY-RUN] Config has placeholder values -- interactive setup would run here." -ForegroundColor DarkYellow
    Write-Host ""
}

# --- Reload effective values ---
$domain = $config.tenant.domain
$subId  = $config.tenant.subscriptionId
$loc    = $config.tenant.location
$rg     = $config.infrastructure.resourceGroup
$agents = $config.agents

$script:PreselectedExistingUsers = $false
if ($freshDefinitions -and $UseExistingUsers -and -not $DryRun) {
    Write-Host "=== Step 0: Selecting existing users for this fresh installation ===" -ForegroundColor Cyan
    Write-Host "  Users selected here will be stored in Installation_definitions.json and used by the environment scan." -ForegroundColor Gray
    $selectedAgents = & (Join-Path $PSScriptRoot 'modules\Select-ExistingUsers.ps1') -Domain $config.tenant.domain
    if (-not $selectedAgents -or $selectedAgents.Count -eq 0) {
        Write-Host "  [ERROR] No users selected. Aborting." -ForegroundColor Red
        Stop-Transcript | Out-Null
        return
    }

    $agents = $selectedAgents
    $config.agents = $selectedAgents
    $config.features.userMode = 'existing'
    Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 5)
    Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
        -RunLogPath $runLogPath -RunStamp $runStamp
    Set-AAInstallationDefinition -Path $installationDefinitionsPath -Section 'selectedUsers' -Value @($selectedAgents | ForEach-Object {
        [ordered]@{
            sam = $_.sam
            userPrincipalName = $_.userPrincipalName
            displayName = $_.displayName
            department = $_.department
            jobTitle = $_.jobTitle
            wave = $_.wave
            workload = $_.workload
            keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $config.tenant.domain
        }
    })
    $script:PreselectedExistingUsers = $true
    Write-Host "  Selected users saved to $installationDefinitionsPath" -ForegroundColor Green
    Write-Host ""
}
Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
    -RunLogPath $runLogPath -RunStamp $runStamp

$w1Count = @($agents | Where-Object { $_.wave -eq 1 }).Count
$w2Count = @($agents | Where-Object { $_.wave -eq 2 }).Count

Write-Host "  Tenant:       $domain" -ForegroundColor Gray
Write-Host "  Subscription: $subId" -ForegroundColor Gray
Write-Host "  Location:     $loc" -ForegroundColor Gray
Write-Host "  RG:           $rg" -ForegroundColor Gray
Write-Host "  Agents:       $(Format-AAAgentWaveSummary -AgentList $agents)" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# ENVIRONMENT PROBE - detect what already exists in the target tenant
# ============================================================================
# Checks Azure resources, Entra users, and app registration.
# Displays a dashboard so the admin knows exactly what will be created vs skipped.
if (-not $DryRun -and $domain -notmatch 'REPLACE_WITH') {
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  ENVIRONMENT SCAN - Checking existing resources" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    $probeResults = @{}

    # -- Check Azure subscription ---
    $currentSub = az account show --query "{id:id,name:name}" -o json 2>$null | ConvertFrom-Json
    if ($currentSub -and $currentSub.id -eq $subId) {
        Write-Host "  [OK]  Subscription: $($currentSub.name)" -ForegroundColor Green
        $probeResults['subscription'] = 'ok'
    } else {
        Write-Host "  [SET] Switching to subscription $subId..." -NoNewline
        az account set -s $subId 2>$null
        $verify = az account show --query name -o tsv 2>$null
        if ($verify) {
            Write-Host " $verify" -ForegroundColor Green
            $probeResults['subscription'] = 'ok'
        } else {
            Write-Host " [FAILED]" -ForegroundColor Red
            $probeResults['subscription'] = 'missing'
        }
    }

    # -- Credential health check: a failed query must NOT be reported as [NEW] ---
    # The probes below use 'az ... 2>$null', which looks identical for "resource
    # missing" and "token expired". Validate both planes once up front instead.
    az group list --query "[0].name" -o tsv *> $null
    $armOk = ($LASTEXITCODE -eq 0)
    az ad signed-in-user show --query id -o tsv *> $null
    $graphOk = ($LASTEXITCODE -eq 0)
    if (-not $armOk -or -not $graphOk) {
        $failedPlanes = @()
        if (-not $armOk) { $failedPlanes += 'Azure Resource Manager' }
        if (-not $graphOk) { $failedPlanes += 'Microsoft Graph' }
        Write-Host "  [WARN] $($failedPlanes -join ' and ') queries are failing (expired session?)." -ForegroundColor Yellow
        Write-Host "         Items below may show as [NEW] even if they already exist." -ForegroundColor Yellow
        Write-Host "         Run: az login --tenant $($config.tenant.tenantId)  then rerun the wizard." -ForegroundColor Yellow
        Write-Host ""
    }

    # -- Check Resource Group ---
    $rgExists = az group show -n $rg --query name -o tsv 2>$null
    if ($rgExists) {
        Write-Host "  [OK]  Resource group: $rg" -ForegroundColor Green
        $probeResults['rg'] = 'exists'
    } else {
        Write-Host "  [NEW] Resource group: $rg (will be created at Step 4)" -ForegroundColor DarkYellow
        $probeResults['rg'] = 'new'
    }

    # -- Check Azure OpenAI ---
    $oaiName = $config.infrastructure.openAiAccountName
    $oaiExists = az cognitiveservices account show -n $oaiName -g $rg --query name -o tsv 2>$null
    if ($oaiExists) {
        Write-Host "  [OK]  Azure OpenAI: $oaiName" -ForegroundColor Green
        $probeResults['openai'] = 'exists'
    } else {
        $oaiSubWide = az cognitiveservices account list --query "[?name=='$oaiName'].{name:name,rg:resourceGroup}" -o json 2>$null | ConvertFrom-Json
        if ($oaiSubWide -and $oaiSubWide.Count -gt 0) {
            $script:oaiActualRg = $oaiSubWide[0].rg
            Write-Host "  [OK]  Azure OpenAI: $oaiName (in $($script:oaiActualRg))" -ForegroundColor Green
            $probeResults['openai'] = 'exists'
        } else {
            Write-Host "  [NEW] Azure OpenAI: $oaiName (will be created at Step 4)" -ForegroundColor DarkYellow
            $probeResults['openai'] = 'new'
        }
    }

    # -- Check Automation Account (search in target RG, then subscription-wide) ---
    $aaName = $config.infrastructure.automationAccountName
    if (Test-AAAutomationAccountAvailable -Config $config) {
        Write-Host "  [OK]  Automation: $aaName" -ForegroundColor Green
        $probeResults['automation'] = 'exists'
        $script:aaActualRg = $rg
    } else {
        Write-Host "  [NEW] Automation: $aaName (will be created at Step 4)" -ForegroundColor DarkYellow
        $probeResults['automation'] = 'new'
        $script:aaActualRg = $rg
    }

    # -- Check Entra app registration ---
    $appExists = az ad app list --display-name 'app-claudia-dataagent' --query "[0].appId" -o tsv 2>$null
    if ($appExists) {
        Write-Host "  [OK]  Entra app: app-claudia-dataagent ($appExists)" -ForegroundColor Green
        $probeResults['app'] = 'exists'
    } else {
        Write-Host "  [NEW] Entra app: app-claudia-dataagent (will be created at Step 3)" -ForegroundColor DarkYellow
        $probeResults['app'] = 'new'
    }

    # -- Check agent users (sample first + last) ---
    $firstAgent = $agents[0]
    $lastAgent  = $agents[-1]
    $firstUpn = Get-AgentUpn -Agent $firstAgent -Domain $domain
    $lastUpn  = Get-AgentUpn -Agent $lastAgent -Domain $domain
    $firstExists = az ad user show --id $firstUpn --query displayName -o tsv 2>$null
    $lastExists  = az ad user show --id $lastUpn --query displayName -o tsv 2>$null
    if ($firstExists -and $lastExists) {
        Write-Host "  [OK]  Agent users: $firstExists ... $lastExists (all likely exist)" -ForegroundColor Green
        $probeResults['users'] = 'exists'
    } elseif ($firstExists) {
        Write-Host "  [MIX] Agent users: $firstExists exists, $($lastAgent.displayName) missing" -ForegroundColor DarkYellow
        $probeResults['users'] = 'partial'
    } else {
        Write-Host "  [NEW] Agent users: none found (will be created at Step 1)" -ForegroundColor DarkYellow
        $probeResults['users'] = 'new'
    }

    # -- Summary ---
    $existCount = @($probeResults.Values | Where-Object { $_ -eq 'exists' }).Count
    $newCount   = @($probeResults.Values | Where-Object { $_ -in @('new','partial') }).Count
    $totalProbe = $probeResults.Count
    Write-Host ""

    Set-AAInstallationDefinition -Path $installationDefinitionsPath -Section 'environmentScan' -Value ([ordered]@{
        collectedAt = (Get-Date).ToString('o')
        results = $probeResults
        existingCount = $existCount
        newOrPartialCount = $newCount
        total = $totalProbe
        actualResourceGroups = [ordered]@{
            automation = $script:aaActualRg
            openAi = $script:oaiActualRg
        }
    })
    if ($newCount -eq 0) {
        Write-Host "  All $totalProbe components already exist. The wizard will verify and update." -ForegroundColor Green
    } elseif ($existCount -eq 0) {
        Write-Host "  Fresh environment detected. All $totalProbe components will be created." -ForegroundColor Cyan
    } else {
        Write-Host "  Mixed environment: $existCount existing + $newCount to create." -ForegroundColor Yellow
    }
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    # Always ask before proceeding - env scan is informational, deployment is destructive
    $proceed = if ($Auto) { 'y' } else { Read-Host "  Continue with deployment? (Y/n)" }
    if ($proceed -eq 'n') {
        Write-Host "  Aborted." -ForegroundColor Red
        Stop-Transcript | Out-Null
        return
    }
    Write-Host ""
} elseif ($DryRun) {
    Write-Host "  [DRY-RUN] Environment probe skipped (would check Azure + Entra resources)." -ForegroundColor DarkYellow
    Write-Host ""
}

# ============================================================================
# STEPS 0..10 (bodies extracted to modules\steps\, dot-sourced so they run
# in the installer scope with identical variable semantics). A step that
# must abort the whole install sets $script:AAInstallAborted then returns;
# the orchestrator stops before the next step (and before the SUMMARY),
# exactly like the original top-level 'return' statements did.
# ============================================================================
$installRoot = $PSScriptRoot
$installBoundParams = $PSBoundParameters
$script:AAInstallAborted = $false
foreach ($stepFileName in @(
    'Step0-Prerequisites', 'Step1-AgentUsers', 'Step2-Licenses', 'Step3-EntraApp',
    'Step4-AzureInfra', 'Step4a-M365Collaboration', 'Step4b-SensitivityLabels', 'Step4c-Fabric',
    'Step5-SecretsRunbook', 'Step6a-CoreDLP', 'Step6b-DspmAI', 'Step6c-IRM',
    'Step7-Workbook', 'Step8-StoryMap', 'Step9-BrowserAgents', 'Step10-MdcaConnector')) {
    . (Join-Path $PSScriptRoot "modules\steps\$stepFileName.ps1")
    if ($script:AAInstallAborted) { return }
}

# ============================================================================
# SUMMARY
# ============================================================================
$expectedResults = @(
    @{Step="0"; Activity="Prerequisite validation"; Runs=((Test-AAInstallStep '0') -and -not $SkipPrerequisites); SkipComment="Skipped by parameter or targeted step selection."},
    @{Step="1"; Activity="Create or select agent users"; Runs=(Test-AAInstallStep '1'); SkipComment="Skipped by targeted step selection."},
    @{Step="1b"; Activity="Persona profile photos"; Runs=(Test-AAInstallStep '1'); SkipComment="Optional prompt inside Step 1."},
    @{Step="2"; Activity="Licenses and MFA exclusion"; Runs=(Test-AAInstallStep '2'); SkipComment="Skipped by targeted step selection."},
    @{Step="3"; Activity="Register app-claudia-dataagent"; Runs=(Test-AAInstallStep '3'); SkipComment="Skipped by targeted step selection."},
    @{Step="4"; Activity="Azure infrastructure and Key Vault"; Runs=(Test-AAInstallStep '4'); SkipComment="Skipped by targeted step selection."},
    @{Step="4a"; Activity="M365 collaboration"; Runs=(Test-AAInstallStep '4a'); SkipComment="Skipped by targeted step selection."},
    @{Step="4b"; Activity="Sensitivity labels"; Runs=(Test-AAInstallStep '4b'); SkipComment="Skipped by targeted step selection."},
    @{Step="4c"; Activity="Fabric provisioning"; Runs=((Test-AAInstallStep '4c') -and $config.infrastructure.fabricEnabled); SkipComment="fabricEnabled=false or skipped by targeted step selection."},
    @{Step="5"; Activity="Key Vault secrets and runbook"; Runs=(Test-AAInstallStep '5'); SkipComment="Skipped by targeted step selection."},
    @{Step="6a"; Activity="Core DLP policies"; Runs=(Test-AAInstallStep '6a'); SkipComment="Skipped by targeted step selection."},
    @{Step="6b"; Activity="DSPM for AI policies"; Runs=(Test-AAInstallStep '6b'); SkipComment="Skipped by targeted step selection."},
    @{Step="6c"; Activity="Insider Risk Management"; Runs=(Test-AAInstallStep '6c'); SkipComment="Skipped by targeted step selection."},
    @{Step="7"; Activity="ClaudIA Activity Monitor workbook"; Runs=(Test-AAInstallStep '7'); SkipComment="Skipped by targeted step selection."},
    @{Step="8"; Activity="Activity Story Map"; Runs=(Test-AAInstallStep '8'); SkipComment="Skipped by targeted step selection."},
    @{Step="9"; Activity="BrowserAgent cloud automation"; Runs=(Test-AAInstallStep '9'); SkipComment="Optional BrowserAgent cloud layer skipped by targeted step selection or prompt."},
    @{Step="10"; Activity="MDCA Cloud Discovery connector"; Runs=(Test-AAInstallStep '10'); SkipComment="Optional MDCA Cloud Discovery connector skipped by targeted step selection or prompt."}
)
foreach ($item in $expectedResults) {
    if (-not ($script:AADeploymentResults | Where-Object { $_.Step -eq $item.Step })) {
        if ($item.Runs) {
            $status = 'deployed'
            $comment = 'Completed in this run. Review module output above for detailed actions.'
        } else {
            $status = 'skipped'
            $comment = $item.SkipComment
        }
        Set-AADeploymentResult -Step $item.Step -MainActivity $item.Activity -Status $status -Comments $comment
    }
}
Set-AAInstallationDefinition -Path $installationDefinitionsPath -Section 'deploymentResults' -Value $script:AADeploymentResults

Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT RESULTS" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
$script:AADeploymentResults | Sort-Object {
    switch ($_.Step) {
        '0' { 0 } '1' { 1 } '2' { 2 } '3' { 3 } '4' { 4 }
        '4a' { 4.1 } '4b' { 4.2 } '4c' { 4.3 }
        '5' { 5 } '6a' { 6.1 } '6b' { 6.2 } '6c' { 6.3 } '7' { 7 } '8' { 8 } '9' { 9 } '10' { 10 }
        default { 99 }
    }
} | Format-Table -AutoSize
Write-Host "  Full log: $runLogPath" -ForegroundColor Gray
Write-Host "  Installation definitions: $installationDefinitionsPath" -ForegroundColor Gray
Write-Host ""

Write-Host "================================================================" -ForegroundColor Green
if ($script:RunAllSteps) {
    Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
} else {
    Write-Host "  STEP $Step COMPLETE" -ForegroundColor Green
}
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Agents: $(Format-AAAgentWaveSummary -AgentList $agents)" -ForegroundColor White
Write-Host "  Schedules: $($config.schedules.Count)x daily" -ForegroundColor White
Write-Host "  Monitoring: Azure Data Explorer (ADX) + ADX workbook" -ForegroundColor White
Write-Host ""

if ((-not $script:RunAllSteps) -and $Step -lt 5) {
    Write-Host "  Next required step:" -ForegroundColor Cyan
    Write-Host "    .\Install-ClaudIA.ps1 -UseExistingUsers -UseInstallationDefinitions -Step 5" -ForegroundColor White
    Write-Host ""
    Write-Host "  Tests are available after Step 5 deploys the runbook and stores Key Vault secrets." -ForegroundColor Gray
} else {
    Write-Host "  Quick test:" -ForegroundColor Cyan
    Write-Host "    .\tests\Test-SingleAgent.ps1 -Agent $($agents[0].sam)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Full test options:" -ForegroundColor Cyan
    Write-Host "    .\tests\Test-FullRun.ps1                                      # sequential, all configured agents" -ForegroundColor White
    Write-Host "    .\tests\Test-FullRun.ps1 -Agents $($agents[0].sam),$($agents[1].sam) -ADXWaitMinutes 2" -ForegroundColor White
    Write-Host "    .\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 3            # parallel execution" -ForegroundColor White
    Write-Host "    .\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5 -NoADXWait # faster job-only validation" -ForegroundColor White
}

Write-Host ""
Write-Host "  Optional components (deploy only if still needed):" -ForegroundColor Yellow
Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 6 -SkipPrerequisites  # DLP/DSPM/IRM" -ForegroundColor Gray
if ($config.adx -and $config.adx.enabled -eq $true) {
    Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 7 -SkipPrerequisites  # ADX workbook" -ForegroundColor Gray
    Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 8 -SkipPrerequisites  # Activity Story Map" -ForegroundColor Gray
} else {
    Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 7 -SkipPrerequisites  # Workbook" -ForegroundColor Gray
}
Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 9 -SkipPrerequisites  # BrowserAgent cloud automation" -ForegroundColor Gray
Write-Host "    .\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 10 -SkipPrerequisites # MDCA Cloud Discovery connector" -ForegroundColor Gray

if ($config.activityStoryMap -and $config.activityStoryMap.launchUrl) {
    Write-Host ""
    Write-Host "  Activity Story Map:" -ForegroundColor Cyan
    Write-Host "    $($config.activityStoryMap.launchUrl)" -ForegroundColor White
}

if ($script:RunAllSteps -or $Step -eq 6) {
    Write-Host ""
    Write-Host "  Manual portal steps, only if not already completed:" -ForegroundColor Yellow
    Write-Host "    1. IRM > Settings > Policy indicators > Enable 'Generative AI apps'" -ForegroundColor Yellow
    Write-Host "    2. IRM > Priority User Groups > Create 'ClaudIA Agents' with agent UPNs" -ForegroundColor Yellow
    Write-Host "    3. DSPM for AI > Get started (if not already enabled)" -ForegroundColor Yellow
}
Write-Host ""
Stop-Transcript | Out-Null






