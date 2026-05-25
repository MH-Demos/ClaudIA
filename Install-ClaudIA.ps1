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
    Run only a specific step (0-8). Without -Step, the full deployment runs.
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

    === WIZARD FLOW (9 steps, all idempotent) ===

    Step 0: PREREQUISITES
      Runs Test-Prerequisites.ps1 (13 checks: tools, providers, licenses, permissions).
      -> Skip with -SkipPrerequisites if you already validated.

    Step 1: CREATE OR SELECT AGENTS
      Mode 'create': Creates Entra ID users from agents.json, generates shared password.
      Mode 'existing': Launches interactive picker (Select-ExistingUsers.ps1).
      Mode 'prompt': Asks which mode at runtime.
      -> Customize via -UseExistingUsers switch or features.userMode in agents.json.

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
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config\agents.json' }

function Test-AARepositoryStructure {
    $requiredPaths = @(
        'modules\Common.ps1',
        'modules\Deploy-AzureInfra.ps1',
        'modules\Deploy-Runbook.ps1',
        'modules\Invoke-AgentRunbook.ps1',
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

$freshDefinitions = ($script:RunAllSteps -and -not $SkipPrerequisites -and -not $UseInstallationDefinitions)
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
        Write-Host "      Fix: rerun with .\Install-ClaudIA.ps1 -RegisterProviders, or run the az provider register commands shown above." -ForegroundColor DarkYellow
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
        $manualSub = Read-ConfigValue -Label "Azure subscription ID" -Current $Current -Hint "e.g. 84000b2d-4410-4243-bf7e-f813b43bc2bd"
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

# Check if interactive setup is needed
$needsSetup = ($config.tenant.domain -match 'REPLACE_WITH') -or ($config.tenant.subscriptionId -match 'REPLACE_WITH')

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
    if ($newSubId -ne $config.tenant.subscriptionId) { $config.tenant.subscriptionId = $newSubId; $configChanged = $true }

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
    $currentCountry = if ($config.tenant.country) { $config.tenant.country } else { 'FR' }
    Write-Host "    Country [$currentCountry]: " -NoNewline
    $newCountry = Read-Host
    if ($newCountry) {
        $newCountry = $newCountry.ToUpper()
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
            Set-AAConfigProperty -Object $config.infrastructure -Name openAiImageModel -Value 'Dall-e-3'
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
        $config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding utf8
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
    $config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding utf8
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
    $aaExists = az automation account show -n $aaName -g $rg --query name -o tsv 2>$null
    if ($aaExists) {
        Write-Host "  [OK]  Automation: $aaName" -ForegroundColor Green
        $probeResults['automation'] = 'exists'
        $script:aaActualRg = $rg
    } else {
        $aaSubWide = az automation account list --query "[?name=='$aaName'].{name:name,rg:resourceGroup}" -o json 2>$null | ConvertFrom-Json
        if ($aaSubWide -and $aaSubWide.Count -gt 0) {
            $script:aaActualRg = $aaSubWide[0].rg
            Write-Host "  [OK]  Automation: $aaName (in $($script:aaActualRg))" -ForegroundColor Green
            $probeResults['automation'] = 'exists'
        } else {
            Write-Host "  [NEW] Automation: $aaName (will be created at Step 4)" -ForegroundColor DarkYellow
            $probeResults['automation'] = 'new'
            $script:aaActualRg = $rg
        }
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
# STEP 0: PREREQUISITES
# ============================================================================
if ((Test-AAInstallStep '0') -and -not $SkipPrerequisites) {
    Write-Host "=== Step 0: Checking prerequisites ===" -ForegroundColor Cyan
    $prereqArgs = @('-ConfigPath', $ConfigPath)
    if ($RegisterProviders) { $prereqArgs += '-RegisterProviders' }
    $prereq = & (Join-Path $PSScriptRoot 'prerequisites\Test-Prerequisites.ps1') @prereqArgs
    if (-not $prereq.AllPassed) {
        Show-AAPrerequisiteGuidance -PrerequisiteResult $prereq
        Write-Host ""
        Write-Host "[BLOCKED] Fix prerequisite failures before continuing." -ForegroundColor Red
        $continue = if ($Auto) { 'y' } else { Read-Host "  Continue anyway? (y/N)" }
        if ($continue -ne 'y') { return }
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '0' -Value ([ordered]@{
        activity = 'Reset connections and validate prerequisites'
        completedAt = (Get-Date).ToString('o')
        connectionReset = $script:AAInstallationDefinitions.sessionReset
        prerequisitesAllPassed = $prereq.AllPassed
    })
    Set-AADeploymentResult -Step '0' -MainActivity 'Prerequisite validation' -Status 'deployed' -Comments 'Completed; Copilot availability is warning/pending for existing users.'
    Write-Host ""
} elseif ($SkipPrerequisites) {
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '0' -Value ([ordered]@{
        activity = 'Reset connections and validate prerequisites'
        completedAt = (Get-Date).ToString('o')
        skipped = $true
        reason = 'Skipped by parameter.'
    })
    Set-AADeploymentResult -Step '0' -MainActivity 'Prerequisite validation' -Status 'skipped' -Comments 'Skipped by parameter.'
}

# ============================================================================
# STEP 1: CREATE OR SELECT AGENT ACCOUNTS
# ============================================================================
if (Test-AAInstallStep '1') {
    # Determine user mode: config setting, CLI switch, or interactive prompt
    $userMode = $config.features.userMode
    if ($UseExistingUsers) { $userMode = 'existing' }

    if (-not $userMode -or $userMode -eq 'prompt') {
        Write-Host "=== Step 1: Agent Account Setup ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  How do you want to set up agent accounts?" -ForegroundColor White
        Write-Host "    [1] Create new users (default 10 personas from agents.json)" -ForegroundColor Gray
        Write-Host "    [2] Use existing tenant users (interactive picker)" -ForegroundColor Gray
        Write-Host ""
        $modeChoice = if ($Auto) { '1' } else { Read-Host "  Choice (1 or 2)" }
        $userMode = if ($modeChoice -eq '2') { 'existing' } else { 'create' }
    }

    if ($userMode -eq 'existing') {
        Write-Host "=== Step 1: Selecting existing users as agents ===" -ForegroundColor Cyan

        if ($DryRun) {
            Write-Host "  [DRY-RUN] Would launch interactive user picker" -ForegroundColor DarkYellow
            Write-Host "  [DRY-RUN] Selected users would replace agents[] in config" -ForegroundColor DarkYellow
        } elseif ($script:PreselectedExistingUsers) {
            Write-Host "  [OK] Existing users were already selected during Step 0 fresh installation setup." -ForegroundColor Green
        } elseif ($UseInstallationDefinitions -and $config.agents -and @($config.agents).Count -gt 0) {
            $agents = @($config.agents)
            $config | Add-Member -NotePropertyName '_runtimeAgents' -NotePropertyValue $agents -Force
            Write-Host "  [OK] Using $($agents.Count) agents from Installation_definitions.json." -ForegroundColor Green
            Write-Host "       Run tools\\Add-StorylineAgents.ps1 to append storyline expansions without replacing the original cast." -ForegroundColor Gray
        } else {
            $selectedAgents = & (Join-Path $PSScriptRoot 'modules\Select-ExistingUsers.ps1') -Domain $domain
            if (-not $selectedAgents -or $selectedAgents.Count -eq 0) {
                Write-Host "  [ERROR] No users selected. Aborting." -ForegroundColor Red
                return
            }
            # Update config in memory with selected users
            $agents = $selectedAgents
            $config | Add-Member -NotePropertyName '_runtimeAgents' -NotePropertyValue $selectedAgents -Force

            # Save updated agents back to config file
            $configObj = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $configObj.agents = $selectedAgents
            $configObj.features.userMode = 'existing'
            $configObj | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding utf8
            $config = $configObj
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
                    keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $domain
                }
            })
            Write-Host "  Updated $ConfigPath with $($selectedAgents.Count) selected users." -ForegroundColor Green
        }

        $w1Count = @($agents | Where-Object { $_.wave -eq 1 }).Count
        $w2Count = @($agents | Where-Object { $_.wave -eq 2 }).Count
        if (-not $DryRun) {
            Write-Host ""
            Write-Host "  ROPC requires a valid password for each selected existing user." -ForegroundColor Yellow
            if ($PSBoundParameters.ContainsKey('AgentPassword')) {
                $agentPassword = $PSBoundParameters['AgentPassword']
                $resetExistingChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset selected users to -AgentPassword now? (Y/n)" }
            } else {
                $resetExistingChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset selected user passwords to a shared lab password now? (Y/n)" }
                if ($resetExistingChoice -ne 'n') {
                    $agentPassword = Read-Host "  Shared lab password to set (blank = generate)"
                    if (-not $agentPassword) {
                        $agentPassword = -join ((65..90) + (97..122) + (48..57) + (33,35,36,37) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
                    }
                } else {
                    $agentPassword = Read-Host "  Enter the existing shared password to store in Key Vault"
                }
            }

            if ($resetExistingChoice -ne 'n') {
                Write-Host "  Resetting selected user passwords..." -NoNewline
                $resetOk = 0
                foreach ($agent in $agents) {
                    $upn = Get-AgentUpn -Agent $agent -Domain $domain
                    az ad user update --id $upn --password $agentPassword --force-change-password-next-sign-in false -o none 2>$null
                    if ($LASTEXITCODE -eq 0) { $resetOk++ }
                }
                Write-Host " [OK] $resetOk/$($agents.Count) passwords reset" -ForegroundColor Green
                Write-Host "  Shared lab password: $agentPassword" -ForegroundColor Yellow
            } else {
                Write-Host "  [INFO] Passwords were not reset; the entered password will be stored for ROPC." -ForegroundColor DarkYellow
            }
            Write-Host "  (Password will be stored in Key Vault at Step 5.)" -ForegroundColor Gray
        }
        Write-Host ""
    } else {
        Write-Host "=== Step 1: Creating agent accounts in Entra ID ===" -ForegroundColor Cyan
        $agentPassword = -join ((65..90) + (97..122) + (48..57) + (33,35,36,37) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        $existCount = 0
        $createCount = 0

        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            Write-Host "  Creating $($agent.displayName) ($upn)..." -NoNewline

            if ($DryRun) { Write-Host " [DRY-RUN]" -ForegroundColor DarkYellow; continue }

            $existing = az ad user show --id $upn -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host " [EXISTS]" -ForegroundColor DarkYellow
                $existCount++
            } else {
                $createErr = az ad user create --display-name $agent.displayName --user-principal-name $upn `
                    --password $agentPassword --force-change-password-next-sign-in false -o json 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host " [FAIL] $createErr" -ForegroundColor Red
                } else {
                    Write-Host " [OK]" -ForegroundColor Green
                    $createCount++
                }
            }
        }

        # Set usage location + department + jobTitle via Graph PATCH
        $gt = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
        $graphHeaders = @{Authorization="Bearer $gt"; 'Content-Type'='application/json'}
        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            if (-not $DryRun) {
                $userId = az ad user show --id $upn --query id -o tsv 2>$null
                if ($userId) {
                    $body = @{usageLocation='FR'; department=$agent.department; jobTitle=$agent.jobTitle} | ConvertTo-Json
                    Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$userId" `
                        -Headers $graphHeaders -Body $body -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        # Password handling: if ALL users existed, the generated password was never applied
        if ($existCount -eq $agents.Count -and $createCount -eq 0 -and -not $DryRun) {
            Write-Host ""
            Write-Host "  All agents already exist." -ForegroundColor Yellow
            if ($PSBoundParameters.ContainsKey('AgentPassword')) {
                # -AgentPassword provided explicitly on command line - use it directly
                $agentPassword = $PSBoundParameters['AgentPassword']
                Write-Host "  Using provided -AgentPassword." -ForegroundColor Green
            } else {
                Write-Host "  The wizard will RESET their passwords to a new shared password." -ForegroundColor Yellow
                Write-Host "  This requires Global Admin (already verified in prerequisites)." -ForegroundColor Gray
                $resetChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset all agent passwords now? (Y/n)" }
                if ($resetChoice -eq 'n') {
                    Write-Host "  [SKIP] You must provide the password at Step 5." -ForegroundColor DarkYellow
                    Write-Host "  Tip: re-run with -AgentPassword 'yourpassword'" -ForegroundColor Gray
                } else {
                    Write-Host "  Resetting passwords..." -NoNewline
                    $resetOk = 0
                    foreach ($agent in $agents) {
                        $upn = Get-AgentUpn -Agent $agent -Domain $domain
                        az ad user update --id $upn --password $agentPassword --force-change-password-next-sign-in false -o none 2>$null
                        if ($LASTEXITCODE -eq 0) { $resetOk++ }
                    }
                    Write-Host " [OK] $resetOk/$($agents.Count) passwords reset" -ForegroundColor Green
                    Write-Host "  New shared password: $agentPassword" -ForegroundColor Yellow
                }
            }
        } elseif ($createCount -gt 0) {
            Write-Host "  Password for new agents: $agentPassword" -ForegroundColor Yellow
        }
        Write-Host "  (Password will be stored automatically in Step 5.)" -ForegroundColor Gray
        Write-Host ""
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '1' -Value ([ordered]@{
        activity = 'Create or select agent users'
        completedAt = (Get-Date).ToString('o')
        userMode = $userMode
        agentCount = @($agents).Count
        agents = @($agents | ForEach-Object {
            [ordered]@{
                sam = $_.sam
                upn = Get-AgentUpn -Agent $_ -Domain $domain
                displayName = $_.displayName
                department = $_.department
                keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $domain
            }
        })
    })
}

# ============================================================================
# STEP 2: ASSIGN LICENSES + MFA EXCLUSION
# ============================================================================
if (Test-AAInstallStep '2') {
    Write-Host "=== Step 2: Assigning licenses + MFA exclusion ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        $gt = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
        $gh = @{Authorization="Bearer $gt"; 'Content-Type'='application/json'}

        # Find best available license SKU (E3, E5, E7, or equivalent)
        $skus = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/subscribedSkus" -Headers $gh).value
        $eligible = $skus | Where-Object { $_.skuPartNumber -match 'E[357]|SPE_|ENTERPRISEP|EMSPREMIUM|M365_' }
        $copilotSku = $skus | Where-Object { $_.skuPartNumber -match 'Copilot' }

        if ($eligible) {
            $bestSku = $eligible | Sort-Object { $_.prepaidUnits.enabled } -Descending | Select-Object -First 1
            $availLic = $bestSku.prepaidUnits.enabled - $bestSku.consumedUnits
            Write-Host "  Found license: $($bestSku.skuPartNumber) ($availLic available)" -ForegroundColor Cyan

            if ($availLic -le 0) {
                Write-Host "  [WARN] No available licenses to assign. Agents will rely on tenant-wide service enablement." -ForegroundColor Yellow
                Write-Host "         If ROPC fails later, assign licenses manually or increase license count." -ForegroundColor Yellow
            }

            foreach ($agent in $agents) {
                $upn = Get-AgentUpn -Agent $agent -Domain $domain
                # Graph API may not find newly created users immediately (Entra replication delay)
                $userId = $null
                try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
                if (-not $userId) {
                    Write-Host "  [WAIT] $upn not yet replicated -- retrying in 5s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 5
                    try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
                }
                if (-not $userId) { Write-Host "  [SKIP] $upn not found (replication delay)" -ForegroundColor DarkYellow; continue }

                # Try to assign license (will fail gracefully if no seats available)
                if ($availLic -gt 0) {
                    $licBody = @{addLicenses=@(@{skuId=$bestSku.skuId}); removeLicenses=@()} | ConvertTo-Json -Depth 3
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$userId/assignLicense" `
                            -Headers $gh -Body $licBody | Out-Null
                        Write-Host "  $($agent.displayName): $($bestSku.skuPartNumber)" -NoNewline -ForegroundColor Green
                        $availLic--
                    } catch {
                        $licenseError = $_.Exception.Message
                        Write-Host "  $($agent.displayName): license assign failed ($licenseError)" -NoNewline -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "  $($agent.displayName): no seats left (tenant-wide)" -NoNewline -ForegroundColor DarkYellow
                }

                # Assign Copilot if needed
                if ($agent.copilotLicense -and $copilotSku) {
                    $copBody = @{addLicenses=@(@{skuId=$copilotSku[0].skuId}); removeLicenses=@()} | ConvertTo-Json -Depth 3
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$userId/assignLicense" `
                            -Headers $gh -Body $copBody | Out-Null
                        Write-Host " + Copilot" -ForegroundColor Green
                    } catch { Write-Host " + Copilot skipped" -ForegroundColor DarkYellow }
                } else {
                    Write-Host "" # newline
                }
            }
        } else {
            Write-Host "  [WARN] No E3/E5/E7 licenses found in tenant." -ForegroundColor Yellow
            Write-Host "         Agents will rely on tenant-wide service enablement." -ForegroundColor Yellow
            Write-Host "         If ROPC/Graph fails later, assign licenses manually." -ForegroundColor Yellow
        }

        # Create/reuse MFA exclusion group
        Write-Host "  Resolving MFA exclusion group..." -NoNewline
        $grpBody = @{displayName='grp-claudia-agent-mfa-exclusion'; description='ClaudIA agents excluded from MFA for ROPC'; mailEnabled=$false; mailNickname='grp-claudia-mfa'; securityEnabled=$true} | ConvertTo-Json
        $savedMfaGroupId = $null
        if ($savedDefinitions -and $savedDefinitions.steps -and $savedDefinitions.steps.'2' -and $savedDefinitions.steps.'2'.mfaExclusionGroupId) {
            $savedMfaGroupId = $savedDefinitions.steps.'2'.mfaExclusionGroupId
        }
        $grp = $null
        if ($savedMfaGroupId) {
            try {
                $grp = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$savedMfaGroupId" -Headers $gh -ErrorAction Stop
                Write-Host " [EXISTS] $($grp.id)" -ForegroundColor DarkYellow
            } catch {
                Write-Host " [STALE ID]" -ForegroundColor DarkYellow
                Write-Host "  Saved group id '$savedMfaGroupId' was not found; searching by name..." -ForegroundColor DarkYellow
            }
        }
        if (-not $grp) {
            $existingGroups = @((Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq 'grp-claudia-agent-mfa-exclusion'&`$select=id,displayName" -Headers $gh).value)
            if ($existingGroups.Count -gt 0) {
                $grp = $existingGroups[0]
                Write-Host " [EXISTS] $($grp.id)" -ForegroundColor DarkYellow
            } else {
                $grp = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups" -Headers $gh -Body $grpBody
                Write-Host " [OK] $($grp.id)" -ForegroundColor Green
            }
        }

        # Add agents to group
        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            $userId = $null
            try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
            if ($userId) {
                try {
                    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)/members/`$ref" `
                        -Headers $gh -Body (@{'@odata.id'="https://graph.microsoft.com/v1.0/directoryObjects/$userId"} | ConvertTo-Json) | Out-Null
                } catch {} # already member
            }
        }
        Write-Host "  All agents added to MFA exclusion group." -ForegroundColor Green
    } else {
        Write-Host "  [DRY-RUN] Would assign E5 + Copilot licenses and create MFA exclusion group" -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '2' -Value ([ordered]@{
        activity = 'Licenses and MFA exclusion'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        mfaExclusionGroup = 'grp-claudia-agent-mfa-exclusion'
        mfaExclusionGroupId = if ($grp) { $grp.id } else { $null }
        selectedLicenseSku = if ($bestSku) { $bestSku.skuPartNumber } else { $null }
        copilotSku = if ($copilotSku) { $copilotSku[0].skuPartNumber } else { $null }
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })

    Write-Host ""
    Write-Host "  MANUAL STEP REQUIRED:" -ForegroundColor Yellow
    Write-Host "    1. Go to Entra admin center > Conditional Access" -ForegroundColor Yellow
    Write-Host "    2. Edit your MFA policy > Exclude > Groups > Add 'grp-claudia-agent-mfa-exclusion'" -ForegroundColor Yellow
    Write-Host "    3. Save the policy" -ForegroundColor Yellow
    Write-Host ""
    if (-not $Auto -and -not $DryRun) {
        Read-Host "  Press Enter when done (or skip if CA is not enforced)"
    } elseif ($Auto) {
        Write-Host "  [AUTO] Skipping MFA manual step -- ensure CA exclusion is configured" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# ============================================================================
# STEP 3: REGISTER ENTRA APP
# ============================================================================
if (Test-AAInstallStep '3') {
    Write-Host "=== Step 3: Registering Entra app (app-claudia-dataagent) ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        & (Join-Path $PSScriptRoot 'modules\Register-AgentApp.ps1') -Domain $domain
    } else {
        Write-Host "  [DRY-RUN] Would register app with delegated scopes for ROPC" -ForegroundColor DarkYellow
    }
    $appDataAgentId = if (-not $DryRun) { az ad app list --display-name 'app-claudia-dataagent' --query "[0].appId" -o tsv 2>$null } else { $null }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '3' -Value ([ordered]@{
        activity = 'Register app-claudia-dataagent'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        appName = 'app-claudia-dataagent'
        appId = $appDataAgentId
    })
    Write-Host ""
}

# ============================================================================
# STEP 4: DEPLOY AZURE INFRASTRUCTURE
# ============================================================================
if (Test-AAInstallStep '4') {
    Write-Host "=== Step 4: Deploying Azure infrastructure ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        $step4Auto = [bool]($Auto -or $UseInstallationDefinitions)
        & (Join-Path $PSScriptRoot 'modules\Deploy-AzureInfra.ps1') -Config $config -Auto:$step4Auto
        if ($config.adx -and $config.adx.enabled -eq $true) {
            & (Join-Path $PSScriptRoot 'tools\Deploy-AdxTelemetry.ps1') -InstallationDefinitionsPath $installationDefinitionsPath
            $savedAfterAdx = Get-Content $installationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($savedAfterAdx.adx) {
                if ($config.PSObject.Properties['adx']) { $config.adx = $savedAfterAdx.adx }
                else { $config | Add-Member -NotePropertyName adx -NotePropertyValue $savedAfterAdx.adx -Force }
            }
        }
        $config | ConvertTo-Json -Depth 30 | Set-Content $ConfigPath -Encoding utf8
        Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
            -RunLogPath $runLogPath -RunStamp $runStamp
    } else {
        Write-Host "  [DRY-RUN] Would create: Azure OpenAI, Automation Account, Key Vault access, and ADX telemetry" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4' -Value ([ordered]@{
        activity = 'Azure infrastructure and Key Vault'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        resourceGroup = $config.infrastructure.resourceGroup
        automationAccountName = $config.infrastructure.automationAccountName
        openAiAccountName = $config.infrastructure.openAiAccountName
        openAiModel = $config.infrastructure.openAiModel
        openAiModelVersion = $config.infrastructure.openAiModelVersion
        openAiImageModel = $config.infrastructure.openAiImageModel
        openAiImageModelVersion = $config.infrastructure.openAiImageModelVersion
        adx = $config.adx
        keyVaultName = Get-KeyVaultName -Config $config
        fabricEnabled = $config.infrastructure.fabricEnabled
    })
    Write-Host ""
}

# ============================================================================
# STEP 4a: M365 COLLABORATION (SharePoint + Teams)
# ============================================================================
if (Test-AAInstallStep '4a') {
    Write-Host "=== Step 4a: M365 Collaboration (SharePoint + Teams) ===" -ForegroundColor Cyan
    Write-Host "  Creates SharePoint site + Teams team + department channels." -ForegroundColor Gray
    Write-Host "  Agents upload files and post activity here." -ForegroundColor Gray
    Write-Host ""

    if (-not $DryRun) {
        Write-Host "    [C] Create new site + team (default)" -ForegroundColor Gray
        Write-Host "    [E] Use existing resources (enter IDs)" -ForegroundColor Gray
        $m365Mode = if ($Auto) { 'C' } else { Read-Host "    Choice (C/E)" }
        $m365ModeStr = if ($m365Mode -eq 'E') { 'existing' } else { 'create' }
        & (Join-Path $PSScriptRoot 'modules\Provision-M365Collaboration.ps1') -Config $config -Mode $m365ModeStr
    } else {
        Write-Host "  [DRY-RUN] Would provision SharePoint site + Teams team" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4a' -Value ([ordered]@{
        activity = 'M365 collaboration'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        mode = if ($m365ModeStr) { $m365ModeStr } else { 'dry-run' }
        teamName = 'CorpLab - Departments'
        departments = @('HR', 'Finance', 'Legal', 'Engineering', 'Sales')
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })
    Write-Host ""
}

# ============================================================================
# STEP 4b: SENSITIVITY LABELS (optional)
# ============================================================================
if (Test-AAInstallStep '4b') {
    Write-Host "=== Step 4b: Sensitivity Labels ===" -ForegroundColor Cyan
    Write-Host "  Creates General, Confidential, Conf-HR, Conf-Finance, Highly Confidential labels." -ForegroundColor Gray
    Write-Host "  Required for agent file classification. Optional if labels already exist." -ForegroundColor Gray
    Write-Host ""

    if (-not $DryRun) {
        $deployLabels = if ($Auto) { 'y' } else { Read-Host "  Deploy sensitivity labels? (Y/n)" }
        if ($deployLabels -ne 'n') {
            & (Join-Path $PSScriptRoot 'modules\Provision-SensitivityLabels.ps1') -Config $config
        } else {
            Write-Host "  [SKIP] Labels skipped. Ensure they exist for file classification." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 5 sensitivity labels + publish policy" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4b' -Value ([ordered]@{
        activity = 'Sensitivity labels'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployLabels) { $deployLabels -ne 'n' } else { -not $DryRun }
        labels = @('General', 'Confidential', 'Conf-HR', 'Conf-Finance', 'Highly Confidential')
        policyName = 'CorpLab-Labels-Policy'
    })
    Write-Host ""
}

# ============================================================================
# STEP 4c: FABRIC PROVISIONING (conditional)
# ============================================================================
if ((Test-AAInstallStep '4c') -and $config.infrastructure.fabricEnabled) {
    Write-Host "=== Step 4c: Fabric Provisioning ===" -ForegroundColor Cyan
    Write-Host "  Creates Fabric F2 capacity, workspace, and lakehouse for Engineering data." -ForegroundColor Gray
    Write-Host "  Cost: ~`$0.36/hr (~`$260/month if running 24/7)." -ForegroundColor Gray
    Write-Host ""

    if (-not $DryRun) {
        Write-Host "    [C] Create new Fabric resources (default)" -ForegroundColor Gray
        Write-Host "    [E] Use existing workspace + lakehouse (enter IDs)" -ForegroundColor Gray
        $fabMode = if ($Auto) { 'C' } else { Read-Host "    Choice (C/E)" }
        $fabModeStr = if ($fabMode -eq 'E') { 'existing' } else { 'create' }
        & (Join-Path $PSScriptRoot 'modules\Provision-Fabric.ps1') -Config $config -Mode $fabModeStr
    } else {
        Write-Host "  [DRY-RUN] Would provision Fabric F2 + workspace + lakehouse" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4c' -Value ([ordered]@{
        activity = 'Fabric provisioning'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        enabled = $true
        mode = if ($fabModeStr) { $fabModeStr } else { 'dry-run' }
    })
    Write-Host ""
} elseif ((Test-AAInstallStep '4c') -and -not $config.infrastructure.fabricEnabled) {
    Write-Host "=== Step 4c: Fabric [DISABLED] ===" -ForegroundColor DarkGray
    Write-Host "  Set fabricEnabled=true in agents.json to enable." -ForegroundColor DarkGray
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4c' -Value ([ordered]@{
        activity = 'Fabric provisioning'
        completedAt = (Get-Date).ToString('o')
        enabled = $false
        reason = 'fabricEnabled=false'
    })
    Write-Host ""
}

# ============================================================================
# STEP 5: STORE SECRETS + DEPLOY RUNBOOK
# ============================================================================
if (Test-AAInstallStep '5') {
    Write-Host "=== Step 5: Storing secrets + deploying runbook ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        # Password may already be set from Step 1 (new users or auto-reset)
        if (-not $agentPassword -and $PSBoundParameters.ContainsKey('AgentPassword')) {
            $agentPassword = $PSBoundParameters['AgentPassword']
        }
        if (-not $agentPassword) {
            Write-Host "  No -AgentPassword provided. Existing per-agent Key Vault secrets will be preserved." -ForegroundColor Cyan
            Write-Host "  Provide -AgentPassword only when intentionally writing one shared password to every agent secret." -ForegroundColor Gray
        }
        & (Join-Path $PSScriptRoot 'modules\Deploy-Runbook.ps1') -Config $config -AgentPassword $agentPassword
    } else {
        Write-Host "  [DRY-RUN] Would preserve/write Key Vault secrets, update Automation variables, and publish runbook" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '5' -Value ([ordered]@{
        activity = 'Key Vault secrets and runbook'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        keyVaultName = Get-KeyVaultName -Config $config
        clientSecretName = 'agent-client-secret'
        agentSecretNames = @($agents | ForEach-Object {
            [ordered]@{
                upn = Get-AgentUpn -Agent $_ -Domain $domain
                secretName = Get-AgentSecretName -Agent $_ -Domain $domain
            }
        })
        runbookName = 'Invoke-AgentRunbook'
        schedules = $config.schedules
    })
    Write-Host ""
}

# ============================================================================
# STEP 6a: CORE DLP POLICIES (optional - 6 workload policies)
# ============================================================================
if (Test-AAInstallStep '6a') {
    Write-Host "=== Step 6a: Core DLP Policies (6 workload policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys category-based DLP policies: Exchange, SharePoint, OneDrive, Teams, Endpoint, Copilot." -ForegroundColor Gray
    Write-Host "  All in AUDIT mode (TestWithNotifications). Optional but recommended." -ForegroundColor Gray

    $deployCoreDlp = 'y'
    if (-not $DryRun) {
        $deployCoreDlp = if ($Auto) { 'y' } else { Read-Host "  Deploy core DLP policies? (Y/n)" }
        if ($deployCoreDlp -ne 'n') {
            & (Join-Path $PSScriptRoot 'modules\Configure-CoreDLP.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] Core DLP policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 6 workload DLP policies with category-based rules" -ForegroundColor DarkYellow
    }
    $coreDlpPolicySuffix = if ([string]::IsNullOrWhiteSpace($domain)) { 'TENANT' } else { (($domain -split '\.')[0]).ToUpperInvariant() }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6a' -Value ([ordered]@{
        activity = 'Core DLP policies'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployCoreDlp) { $deployCoreDlp -ne 'n' } else { -not $DryRun }
        policies = @(
            "EXO Policy - $coreDlpPolicySuffix",
            "SPO Policy - $coreDlpPolicySuffix",
            "ODB Policy - $coreDlpPolicySuffix",
            "Teams Policy - $coreDlpPolicySuffix",
            "Endpoint Policy - $coreDlpPolicySuffix",
            "Copilot Policy - $coreDlpPolicySuffix"
        )
    })
    Write-Host ""
}

# ============================================================================
# STEP 6b: DSPM FOR AI POLICIES (optional - 3 policies)
# ============================================================================
if (Test-AAInstallStep '6b') {
    Write-Host "=== Step 6b: DSPM for AI Policies (3 policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys 3 DSPM DLP policies for AI/Copilot governance." -ForegroundColor Gray

    $deployDspm = 'y'
    if (-not $DryRun) {
        $deployDspm = if ($Auto) { 'y' } else { Read-Host "  Deploy DSPM for AI policies? (Y/n)" }
        if ($deployDspm -ne 'n') {
            & (Join-Path $PSScriptRoot 'modules\Configure-DLP.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] DSPM policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 3 DSPM DLP policies + IRM instructions" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6b' -Value ([ordered]@{
        activity = 'DSPM for AI policies'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployDspm) { $deployDspm -ne 'n' } else { -not $DryRun }
        policies = @('DLP-CopilotStudio-PII-Monitor','DSPM-AI-Labels-Restrict','DSPM-AI-ClaudIAActivity-Audit')
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })
    Write-Host ""
}

# ============================================================================
# STEP 6c: INSIDER RISK MANAGEMENT (optional - 2 policies)
# ============================================================================
if (Test-AAInstallStep '6c') {
    Write-Host "=== Step 6c: Insider Risk Management (2 policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys IRM-DataLeaks-Lab (DLP-triggered) + IRM-RiskyAI-Lab." -ForegroundColor Gray
    Write-Host "  Requires core DLP policies from Step 6a. Optional." -ForegroundColor Gray

    $deployIrm = 'y'
    if (-not $DryRun) {
        $deployIrm = if ($Auto) { 'y' } else { Read-Host "  Deploy IRM policies? (Y/n)" }
        if ($deployIrm -ne 'n') {
            & (Join-Path $PSScriptRoot 'modules\Configure-IRM.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] IRM policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 2 IRM policies (DataLeaks + RiskyAI)" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6c' -Value ([ordered]@{
        activity = 'Insider Risk Management'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployIrm) { $deployIrm -ne 'n' } else { -not $DryRun }
        policies = @('IRM-DataLeaks-Lab','IRM-RiskyAI-Lab')
        priorityUserGroup = 'ClaudIA Agents'
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })
    Write-Host ""
}

# ============================================================================
# STEP 7: DEPLOY WORKBOOK (optional)
# ============================================================================
if (Test-AAInstallStep '7') {
    Write-Host "=== Step 7: ClaudIA Activity Monitor Workbook ===" -ForegroundColor Cyan
    Write-Host "  Deploys Azure Monitor workbook backed by ADX telemetry. Optional." -ForegroundColor Gray

    $deployWb = 'y'
    if (-not $DryRun) {
        $deployWb = if ($Auto) { 'y' } else { Read-Host "  Deploy workbook? (Y/n)" }
        if ($deployWb -ne 'n') {
            & (Join-Path $PSScriptRoot 'modules\Deploy-Workbook.ps1') -Config $config
        } else {
            Write-Host "  [SKIP] Workbook skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would deploy Azure Monitor workbook with KQL queries" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '7' -Value ([ordered]@{
        activity = 'ClaudIA Activity Monitor workbook'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployWb) { $deployWb -ne 'n' } else { -not $DryRun }
        workbookName = 'ClaudIA Activity Monitor'
        telemetryBackend = 'ADX'
    })
    Write-Host ""
}

# ============================================================================
# STEP 8: DEPLOY ACTIVITY STORY MAP (optional)
# ============================================================================
if (Test-AAInstallStep '8') {
    Write-Host "=== Step 8: Activity Story Map ===" -ForegroundColor Cyan
    Write-Host "  Deploys an Azure Storage static website and Azure Function backed by ADX." -ForegroundColor Gray

    $deployStoryMap = 'y'
    $storyMapResult = $null
    if (-not $DryRun) {
        $deployStoryMap = if ($Auto) { 'y' } else { Read-Host "  Deploy Activity Story Map? (Y/n)" }
        if ($deployStoryMap -ne 'n') {
            $storyMapResult = & (Join-Path $PSScriptRoot 'modules\Deploy-ActivityStoryMap.ps1') `
                -Config $config `
                -ConfigPath $ConfigPath `
                -InstallationDefinitionsPath $installationDefinitionsPath
            if ($storyMapResult) {
                Set-AAObjectProperty -Object $config -Name 'activityStoryMap' -Value $storyMapResult
            }
        } else {
            Write-Host "  [SKIP] Activity Story Map skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would deploy Activity Story Map Storage site + Azure Function API" -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '8' -Value ([ordered]@{
        activity = 'Activity Story Map'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployStoryMap) { $deployStoryMap -ne 'n' } else { -not $DryRun }
        staticWebsiteUrl = if ($storyMapResult) { $storyMapResult.staticWebsiteUrl } else { $null }
        apiBaseUrl = if ($storyMapResult) { $storyMapResult.apiBaseUrl } else { $null }
        functionAppName = if ($storyMapResult) { $storyMapResult.functionAppName } else { $null }
    })
    Write-Host ""
}

# ============================================================================
# SUMMARY
# ============================================================================
$expectedResults = @(
    @{Step="0"; Activity="Prerequisite validation"; Runs=((Test-AAInstallStep '0') -and -not $SkipPrerequisites); SkipComment="Skipped by parameter or targeted step selection."},
    @{Step="1"; Activity="Create or select agent users"; Runs=(Test-AAInstallStep '1'); SkipComment="Skipped by targeted step selection."},
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
    @{Step="8"; Activity="Activity Story Map"; Runs=(Test-AAInstallStep '8'); SkipComment="Skipped by targeted step selection."}
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
        '5' { 5 } '6a' { 6.1 } '6b' { 6.2 } '6c' { 6.3 } '7' { 7 } '8' { 8 }
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
