<#PSScriptInfo

.VERSION 1.0.0

.GUID 1302c2f1-b2f7-4384-b055-a117d6b2bc1b

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
Clean end-to-end installer for an ADX-backed autonomous agents lab

.RELEASENOTES
Initial version metadata for Clean end-to-end installer for an ADX-backed autonomous agents lab.

#>
<#
.SYNOPSIS
    Clean end-to-end installer for an ADX-backed autonomous agents lab.
.DESCRIPTION
    Orchestrates the existing installer/modules in the intended order for a new
    subscription/resource group while keeping agent telemetry in Azure Data Explorer.

    The script updates config/agents.json, runs the base wizard steps, provisions
    ADX, publishes the runbook with ADX config, optionally adds storyline agents,
    and can run a smoke test.
.EXAMPLE
    .\tools\Install-CleanAdxLab.ps1 `
      -SubscriptionId 00000000-0000-0000-0000-000000000000 `
      -ResourceGroup IA-NewDemo `
      -Location eastus `
      -AutomationAccountName newdemo-agents `
      -OpenAiAccountName oai-newdemo-1234 `
      -KeyVaultName kvnewdemo1234 `
      -AdxClientSecret "<secret>" `
      -UseExistingUsers `
      -Auto
.EXAMPLE
    .\tools\Install-CleanAdxLab.ps1 -DryRun
#>
param(
    [string]$ConfigPath,
    [string]$InstallationDefinitionsPath,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$Domain,
    [string]$AutomationAccountName,
    [string]$OpenAiAccountName,
    [string]$KeyVaultName,
    [string]$AdxTenantId,
    [string]$AdxClientId,
    [string]$AdxClientSecret,
    [string]$AdxClientSecretName = 'agent-client-secret',
    [string]$AdxM365Scope = 'https://manage.office.com/.default',
    [switch]$UseExistingUsers,
    [switch]$Auto,
    [switch]$SkipBaseWizard,
    [switch]$SkipAdxProvisioning,
    [switch]$SkipRunbookDeploy,
    [switch]$AddStorylineAgents,
    [switch]$ResetStorylinePasswords,
    [switch]$SkipSmokeTest,
    [string]$SmokeTestAgent = 'ana.rodriguez',
    [switch]$KeepExistingAdxConfig,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config\agents.json' }
if (-not $InstallationDefinitionsPath) { $InstallationDefinitionsPath = Join-Path $repoRoot 'config\Installation_definitions.json' }
$installerPath = Join-Path $repoRoot 'Install-ClaudIA.ps1'
$deployAdxPath = Join-Path $repoRoot 'tools\Deploy-AdxTelemetry.ps1'
$addStorylinePath = Join-Path $repoRoot 'tools\Add-StorylineAgents.ps1'
$testSinglePath = Join-Path $repoRoot 'tests\Test-SingleAgent.ps1'
$commonPath = Join-Path $repoRoot 'modules\Common.ps1'
$deployRunbookPath = Join-Path $repoRoot 'modules\Deploy-Runbook.ps1'

function Write-Stage {
    param([string]$Name)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action
    )
    Write-Stage $Name
    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would run: $Name" -ForegroundColor DarkYellow
        return
    }
    & $Action
}

function Update-Property {
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name,
        $Value
    )
    if ($null -eq $Value -or "$Value" -eq '') { return }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function New-InstallSuffix {
    param([string]$Seed)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Seed-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
}

function Get-InstallNameBase {
    param($Config)

    $domainPart = if ($Config.tenant.domain) { ($Config.tenant.domain -split '\.')[0] } else { 'agents' }
    $base = ($domainPart -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $base) { $base = 'agents' }
    if ($base.Length -gt 12) { $base = $base.Substring(0, 12) }
    return $base
}

function New-InstallOpenAiName {
    param($Config)

    $base = Get-InstallNameBase -Config $Config
    return "oai-$base-$(New-InstallSuffix -Seed "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-openai")"
}

function New-InstallKeyVaultName {
    param($Config)

    $base = Get-InstallNameBase -Config $Config
    if ($base.Length -gt 10) { $base = $base.Substring(0, 10) }
    return "kv$base$(New-InstallSuffix -Seed "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-kv")"
}

function Merge-AdxDefinitionsIntoConfig {
    param($Config, $Definitions)
    if ($Definitions.adx) {
        if ($Config.PSObject.Properties['adx']) { $Config.adx = $Definitions.adx }
        else { $Config | Add-Member -NotePropertyName adx -NotePropertyValue $Definitions.adx -Force }
    }
}

function Initialize-InstallationDefinitions {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$Path
    )

    if (Test-Path $Path) { return }

    $defs = [ordered]@{
        schemaVersion = '1.0'
        runId = (Get-Date -Format 'yyyyMMdd-HHmmss')
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        sourceConfigPath = (Resolve-Path $ConfigPath).Path
        runLogPath = ''
        tenant = $Config.tenant
        infrastructure = $Config.infrastructure
        agents = $Config.agents
    }
    if ($Config.adx) { $defs.adx = $Config.adx }

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $defs | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding utf8
    Write-Host "  Created installation definitions: $Path" -ForegroundColor Green
}

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
if (-not (Test-Path $installerPath)) { throw "Installer not found: $installerPath" }

$config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

Write-Stage 'Prepare configuration'
Update-Property -Object $config.tenant -Name subscriptionId -Value $SubscriptionId
Update-Property -Object $config.tenant -Name location -Value $Location
Update-Property -Object $config.tenant -Name domain -Value $Domain
Update-Property -Object $config.infrastructure -Name resourceGroup -Value $ResourceGroup
Update-Property -Object $config.infrastructure -Name automationAccountName -Value $AutomationAccountName

if ($OpenAiAccountName) {
    Update-Property -Object $config.infrastructure -Name openAiAccountName -Value $OpenAiAccountName
} elseif (-not (Test-Path $InstallationDefinitionsPath)) {
    Update-Property -Object $config.infrastructure -Name openAiAccountName -Value (New-InstallOpenAiName -Config $config)
}

if ($KeyVaultName) {
    Update-Property -Object $config.infrastructure -Name keyVaultName -Value $KeyVaultName
} elseif (-not (Test-Path $InstallationDefinitionsPath)) {
    Update-Property -Object $config.infrastructure -Name keyVaultName -Value (New-InstallKeyVaultName -Config $config)
}

if ($AdxTenantId -or $AdxClientId) {
    if (-not $config.PSObject.Properties['adx']) {
        $config | Add-Member -NotePropertyName adx -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    Update-Property -Object $config.adx -Name enabled -Value $true
    Update-Property -Object $config.adx -Name tenantId -Value $AdxTenantId
    Update-Property -Object $config.adx -Name clientId -Value $AdxClientId
    Update-Property -Object $config.adx -Name clientSecretName -Value $AdxClientSecretName
    Update-Property -Object $config.adx -Name keyVaultName -Value $config.infrastructure.keyVaultName
    Update-Property -Object $config.adx -Name m365Scope -Value $AdxM365Scope
}

if ($config.adx -and -not $KeepExistingAdxConfig -and -not (Test-Path $InstallationDefinitionsPath)) {
    foreach ($prop in @('clusterName','ingestBaseUri','queryBaseUri')) {
        if ($config.adx.PSObject.Properties[$prop]) { $config.adx.PSObject.Properties[$prop].Value = '' }
    }
    Update-Property -Object $config.adx -Name resourceGroup -Value $config.infrastructure.resourceGroup
    Update-Property -Object $config.adx -Name location -Value $config.tenant.location
    Update-Property -Object $config.adx -Name keyVaultName -Value $config.infrastructure.keyVaultName
}

if ($SubscriptionId) {
    Write-Host "  Setting Azure subscription: $SubscriptionId"
    if (-not $DryRun) { az account set -s $SubscriptionId 2>$null }
}

if ($DryRun) {
    Write-Host "  [DRY-RUN] Would update $ConfigPath" -ForegroundColor DarkYellow
} else {
    $config | ConvertTo-Json -Depth 50 | Set-Content -Path $ConfigPath -Encoding utf8
    Write-Host "  Config updated: $ConfigPath" -ForegroundColor Green
    Initialize-InstallationDefinitions -Config $config -Path $InstallationDefinitionsPath
}

if (-not $SkipBaseWizard) {
    Invoke-Step 'Base wizard steps 0-4' {
        foreach ($step in 0, 1, 2, 3, 4) {
            Write-Host "  Running installer step $step..." -ForegroundColor Gray
            $wizardParams = @{
                ConfigPath = $ConfigPath
                Auto = $true
                Step = [int]$step
            }
            if ($UseExistingUsers) { $wizardParams.UseExistingUsers = $true }
            & $installerPath @wizardParams
        }
    }
} else {
    Write-Host "  [SKIP] Base wizard steps skipped." -ForegroundColor DarkYellow
}

if (-not $SkipAdxProvisioning) {
    Invoke-Step 'ADX telemetry provisioning' {
        $adxArgs = @('-InstallationDefinitionsPath', $InstallationDefinitionsPath)
        if ($AdxTenantId) { $adxArgs += @('-TenantId', $AdxTenantId) }
        if ($AdxClientId) { $adxArgs += @('-ClientId', $AdxClientId) }
        if ($AdxClientSecret) { $adxArgs += @('-ClientSecret', $AdxClientSecret) }
        if ($AdxClientSecretName) { $adxArgs += @('-ClientSecretName', $AdxClientSecretName) }
        & $deployAdxPath @adxArgs

        $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $defs = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
        Merge-AdxDefinitionsIntoConfig -Config $config -Definitions $defs
        $config | ConvertTo-Json -Depth 50 | Set-Content -Path $ConfigPath -Encoding utf8
        Write-Host "  ADX settings merged into agents.json." -ForegroundColor Green
    }
} else {
    Write-Host "  [SKIP] ADX provisioning skipped." -ForegroundColor DarkYellow
}

if (-not $SkipRunbookDeploy) {
    Invoke-Step 'Deploy runbook and Automation variables' {
        $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        if (Test-Path $InstallationDefinitionsPath) {
            $defs = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
            Merge-AdxDefinitionsIntoConfig -Config $config -Definitions $defs
        }
        . $commonPath
        & $deployRunbookPath -Config $config
    }
} else {
    Write-Host "  [SKIP] Runbook deployment skipped." -ForegroundColor DarkYellow
}

if ($AddStorylineAgents) {
    Invoke-Step 'Add storyline agents' {
        $storyArgs = @('-AutoFromProfiles', '-StoreInKeyVault', '-UpdateAutomationVariables')
        if ($ResetStorylinePasswords) { $storyArgs += '-ResetPassword' }
        else { $storyArgs += '-NoPasswordReset' }
        & $addStorylinePath @storyArgs

        $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        if (Test-Path $InstallationDefinitionsPath) {
            $defs = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
            Merge-AdxDefinitionsIntoConfig -Config $config -Definitions $defs
        }
        . $commonPath
        & $deployRunbookPath -Config $config
    }
}

if (-not $SkipSmokeTest) {
    Invoke-Step "Smoke test agent $SmokeTestAgent" {
        & $testSinglePath -Agent $SmokeTestAgent -ConfigPath $ConfigPath
    }
} else {
    Write-Host "  [SKIP] Smoke test skipped." -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "Clean ADX lab installation flow complete." -ForegroundColor Green
Write-Host "Config: $ConfigPath"
Write-Host "Definitions: $InstallationDefinitionsPath"



