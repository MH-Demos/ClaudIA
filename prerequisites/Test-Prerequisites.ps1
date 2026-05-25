<#
.SYNOPSIS
    Validates local and cloud prerequisites for installing ClaudIA.
.DESCRIPTION
    This preflight script is intended for a clean workstation or jump box that
    only has the project scripts and support files. It validates the host tools,
    PowerShell version, PowerShell modules, Node/npm BrowserAgents dependencies,
    required project files, Azure CLI login, resource providers, model
    availability, M365 licenses, and admin permissions.

    By default, checks that require an authenticated Azure/Microsoft 365 session
    are executed when Azure CLI is available and logged in. Use -Offline to only
    validate local prerequisites.
.PARAMETER ConfigPath
    Path to config\agents.json.
.PARAMETER Offline
    Skip Azure/Microsoft 365 checks that require network/authentication.
.PARAMETER RegisterProviders
    Register missing Azure resource providers instead of only reporting them.
.PARAMETER SkipBrowserAgents
    Do not validate Node/npm and BrowserAgents dependencies.
.PARAMETER AsJson
    Emit the final result object as JSON.
.PARAMETER M365AzureConfigDir
    Optional isolated Azure CLI profile directory for a separate Microsoft 365/Entra admin account.
.EXAMPLE
    .\prerequisites\Test-Prerequisites.ps1
.EXAMPLE
    .\prerequisites\Test-Prerequisites.ps1 -RegisterProviders
.EXAMPLE
    .\prerequisites\Test-Prerequisites.ps1 -Offline
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [switch]$Offline,
    [switch]$RegisterProviders,
    [switch]$SkipBrowserAgents,
    [switch]$AsJson,
    [string]$M365AzureConfigDir
)

if ($AsJson) {
    function Write-Host {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
            [object[]]$Object,
            [ConsoleColor]$ForegroundColor,
            [ConsoleColor]$BackgroundColor,
            [switch]$NoNewline,
            [object]$Separator
        )
    }
}

$ErrorActionPreference = 'Continue'
$script:Checks = New-Object System.Collections.Generic.List[object]
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$BrowserAgentsPath = Join-Path $ProjectRoot 'BrowserAgents'

function Add-CheckResult {
    param(
        [string]$Category,
        [string]$Name,
        [ValidateSet('Pass','Fail','Warn','Skip')] [string]$Status,
        [string]$Detail = '',
        [string]$Fix = ''
    )

    $color = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        default { 'DarkGray' }
    }

    $label = $Status.ToUpperInvariant().PadRight(4)
    Write-Host ("  [{0}] {1}" -f $label, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    if ($Fix) { Write-Host "         Fix: $Fix" -ForegroundColor DarkYellow }

    $script:Checks.Add([PSCustomObject]@{
        Category = $Category
        Name     = $Name
        Status   = $Status
        Passed   = ($Status -in @('Pass','Warn','Skip'))
        Detail   = $Detail
        Fix      = $Fix
    }) | Out-Null
}

function Invoke-Check {
    param(
        [string]$Category,
        [string]$Name,
        [scriptblock]$Test,
        [string]$Fix = '',
        [switch]$WarningOnly
    )

    try {
        $detail = & $Test
        if ($detail) {
            Add-CheckResult -Category $Category -Name $Name -Status 'Pass' -Detail ([string]$detail)
        } elseif ($WarningOnly) {
            Add-CheckResult -Category $Category -Name $Name -Status 'Warn' -Fix $Fix
        } else {
            Add-CheckResult -Category $Category -Name $Name -Status 'Fail' -Fix $Fix
        }
    } catch {
        if ($WarningOnly) {
            Add-CheckResult -Category $Category -Name $Name -Status 'Warn' -Detail $_.Exception.Message -Fix $Fix
        } else {
            Add-CheckResult -Category $Category -Name $Name -Status 'Fail' -Detail $_.Exception.Message -Fix $Fix
        }
    }
}

function Get-CommandVersion {
    param([string]$Command, [string[]]$Arguments = @('--version'))
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $output = & $cmd.Source @Arguments 2>$null
        return (($output | Select-Object -First 1) -as [string]).Trim()
    } catch {
        return $cmd.Source
    }
}

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-InstalledModuleSummary {
    param([string]$Name)
    $module = Get-Module -ListAvailable $Name -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $module) { return $null }
    return "$($module.Name) $($module.Version)"
}

function ConvertTo-SemVer {
    param([string]$VersionText)
    if ($VersionText -match '(\d+)\.(\d+)\.(\d+)') {
        return [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
    }
    if ($VersionText -match '(\d+)\.(\d+)') {
        return [version]("$($Matches[1]).$($Matches[2]).0")
    }
    return $null
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    try { return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}

function Invoke-AzText {
    param([string[]]$Arguments)
    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($output | Out-String).Trim())
}

function Invoke-M365AzText {
    param([string[]]$Arguments)
    if (-not $M365AzureConfigDir) { return (Invoke-AzText -Arguments $Arguments) }
    $oldConfigDir = $env:AZURE_CONFIG_DIR
    $env:AZURE_CONFIG_DIR = $M365AzureConfigDir
    try {
        & az @Arguments 2>$null
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

function Get-M365GraphToken {
    Invoke-M365AzText -Arguments @('account','get-access-token','--resource','https://graph.microsoft.com','--query','accessToken','-o','tsv')
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    $text = Invoke-AzText -Arguments $Arguments
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json -ErrorAction Stop
}

function Get-RequiredProviders {
    param($Config)

    $providers = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in @(
        'Microsoft.KeyVault',
        'Microsoft.CognitiveServices',
        'Microsoft.Automation',
        'Microsoft.Insights',
        'Microsoft.Storage',
        'Microsoft.Web'
    )) {
        $providers.Add($provider)
    }

    if ($Config -and $Config.adx -and $Config.adx.enabled) {
        $providers.Add('Microsoft.Kusto')
    }
    if ($Config -and $Config.infrastructure -and $Config.infrastructure.fabricEnabled) {
        $providers.Add('Microsoft.Fabric')
    }
    if ($Config -and $Config.activityStoryMap -and $Config.activityStoryMap.frontDoor -and $Config.activityStoryMap.frontDoor.enabled) {
        $providers.Add('Microsoft.Cdn')
    }
    if ($Config -and $Config.browserAgents -and $Config.browserAgents.enabled -and -not $SkipBrowserAgents) {
        foreach ($provider in @(
            'Microsoft.LoadTestService',
            'Microsoft.App',
            'Microsoft.ContainerRegistry',
            'Microsoft.ManagedIdentity',
            'Microsoft.OperationalInsights'
        )) {
            $providers.Add($provider)
        }
    }
    if ($Config -and $Config.PSObject.Properties.Name -contains 'graphMeteredBilling' -and $Config.graphMeteredBilling.enabled) {
        $providers.Add('Microsoft.GraphServices')
    }

    return @($providers | Select-Object -Unique)
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor White
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ClaudIA - Prerequisite Check" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Project root: $ProjectRoot" -ForegroundColor DarkGray
Write-Host ""

$config = Get-Config

Write-Section 'Project Files'
Invoke-Check 'Project Files' 'config\agents.json is readable' {
    if ($config) {
        $domain = if ($config.tenant.domain) { $config.tenant.domain } else { '<missing domain>' }
        "Loaded tenant domain: $domain"
    }
} "Create or restore config\agents.json from the project package."

$requiredPaths = @(
    'Install-ClaudIA.ps1',
    'Manage-Costs.ps1',
    'modules\Deploy-AzureInfra.ps1',
    'modules\Deploy-Runbook.ps1',
    'modules\Invoke-AgentRunbook.ps1',
    'modules\Register-AgentApp.ps1',
    'modules\Provision-M365Collaboration.ps1',
    'modules\Provision-SensitivityLabels.ps1',
    'modules\Configure-DLP.ps1',
    'modules\Configure-CoreDLP.ps1',
    'modules\Configure-IRM.ps1',
    'config\agents.json',
    'config\sit-reference.txt',
    'config\locales'
)

foreach ($path in $requiredPaths) {
    Invoke-Check 'Project Files' $path {
        $fullPath = Join-Path $ProjectRoot $path
        if (Test-Path -LiteralPath $fullPath) { $path }
    } "Restore '$path' from the latest project package."
}

Write-Section 'Local Host'
Invoke-Check 'Local Host' 'PowerShell 7+' {
    if ($PSVersionTable.PSVersion.Major -ge 7) { "PowerShell $($PSVersionTable.PSVersion)" }
} "Install PowerShell 7: winget install Microsoft.PowerShell"

Invoke-Check 'Local Host' 'Running in PowerShell 7 host (pwsh)' {
    if ($PSVersionTable.PSEdition -eq 'Core') { "$($PSVersionTable.PSEdition) edition" }
} "Open a PowerShell 7 terminal, not Windows PowerShell 5.1."

Invoke-Check 'Local Host' 'Execution policy allows local scripts' {
    $policy = Get-ExecutionPolicy -Scope Process
    if ($policy -eq 'Undefined') { $policy = Get-ExecutionPolicy -Scope CurrentUser }
    if ($policy -notin @('Restricted','AllSigned')) { "Policy: $policy" }
} "Run: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"

Invoke-Check 'Local Host' 'PowerShell Gallery access is available' {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo) { "PSGallery: $($repo.InstallationPolicy)" }
} "Run: Register-PSRepository -Default"

Invoke-Check 'Local Host' 'Azure CLI installed' {
    $text = Invoke-AzText -Arguments @('version')
    if ($text) {
        $version = $text | ConvertFrom-Json
        "az $($version.'azure-cli')"
    }
} "Install Azure CLI: winget install Microsoft.AzureCLI"

Invoke-Check 'Local Host' 'Git available (recommended)' {
    $version = Get-CommandVersion -Command 'git'
    if ($version) { $version }
} "Install Git if you will clone or update the repository: winget install Git.Git" -WarningOnly

Write-Section 'PowerShell Modules'
$requiredModules = @(
    @{
        Name = 'Az.Accounts'
        Fix = 'Install-Module Az -Scope CurrentUser -Force -AllowClobber'
    },
    @{
        Name = 'ExchangeOnlineManagement'
        Fix = 'Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force'
    }
)

foreach ($module in $requiredModules) {
    Invoke-Check 'PowerShell Modules' "$($module.Name) module" {
        Get-InstalledModuleSummary -Name $module.Name
    } $module.Fix
}

Invoke-Check 'PowerShell Modules' 'Connect-IPPSSession command available' {
    Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue
    $cmd = Get-Command Connect-IPPSSession -ErrorAction SilentlyContinue
    if ($cmd) { $cmd.Source }
} "Install or update ExchangeOnlineManagement, then reopen PowerShell."

if (-not $SkipBrowserAgents) {
    $browserAgentsEnabled = $true
    if ($config -and $config.browserAgents -and $config.browserAgents.PSObject.Properties.Name -contains 'enabled') {
        $browserAgentsEnabled = [bool]$config.browserAgents.enabled
    }

    Write-Section 'BrowserAgents / Node'
    if (-not $browserAgentsEnabled) {
        Add-CheckResult -Category 'BrowserAgents / Node' -Name 'BrowserAgents enabled in config' -Status 'Skip' -Detail 'browserAgents.enabled is false.'
    } else {
        Invoke-Check 'BrowserAgents / Node' 'BrowserAgents folder exists' {
            if (Test-Path -LiteralPath $BrowserAgentsPath) { $BrowserAgentsPath }
        } "Restore the BrowserAgents folder from the latest project package."

        Invoke-Check 'BrowserAgents / Node' 'BrowserAgents package.json exists' {
            $pkg = Join-Path $BrowserAgentsPath 'package.json'
            if (Test-Path -LiteralPath $pkg) { $pkg }
        } "Restore BrowserAgents\package.json."

        Invoke-Check 'BrowserAgents / Node' 'Node.js 20+ installed' {
            $nodeText = Get-CommandVersion -Command 'node'
            $nodeVersion = ConvertTo-SemVer -VersionText $nodeText
            if ($nodeVersion -and $nodeVersion.Major -ge 20) { $nodeText }
        } "Install Node.js LTS 20 or later: winget install OpenJS.NodeJS.LTS"

        Invoke-Check 'BrowserAgents / Node' 'npm installed' {
            $npmText = Get-CommandVersion -Command 'npm' -Arguments @('--version')
            if ($npmText) { "npm $npmText" }
        } "Install Node.js LTS, then reopen PowerShell."

        Invoke-Check 'BrowserAgents / Node' 'BrowserAgents npm dependencies installed' {
            $nodeModules = Join-Path $BrowserAgentsPath 'node_modules'
            $playwright = Join-Path $BrowserAgentsPath 'node_modules\@playwright\test'
            if ((Test-Path -LiteralPath $nodeModules) -and (Test-Path -LiteralPath $playwright)) {
                'node_modules and @playwright/test found'
            }
        } "Run from ClaudIA\BrowserAgents: npm install" -WarningOnly

        Invoke-Check 'BrowserAgents / Node' 'Playwright CLI available through npx' {
            if ((Test-CommandExists 'npx') -and (Test-Path -LiteralPath (Join-Path $BrowserAgentsPath 'node_modules\@playwright\test'))) {
                $current = Get-Location
                try {
                    Set-Location -LiteralPath $BrowserAgentsPath
                    $output = & npx playwright --version 2>$null
                    if ($LASTEXITCODE -eq 0 -and $output) { ($output | Select-Object -First 1) }
                } finally {
                    Set-Location -LiteralPath $current
                }
            }
        } "Run: npm install in BrowserAgents." -WarningOnly
    }
}

if ($Offline) {
    Write-Section 'Cloud Checks'
    Add-CheckResult -Category 'Cloud Checks' -Name 'Azure and Microsoft 365 checks' -Status 'Skip' -Detail 'Skipped because -Offline was specified.'
} else {
    Write-Section 'Azure CLI / Subscription'
    $azLoggedIn = $false
    Invoke-Check 'Azure CLI / Subscription' 'Azure CLI logged in' {
        $acct = Invoke-AzJson -Arguments @('account','show','-o','json')
        if ($acct -and $acct.user) {
            $script:AzAccount = $acct
            $script:AzLoggedIn = $true
            "$($acct.user.name) / $($acct.name)"
        }
    } "Run: az login --tenant YOUR_TENANT_ID"
    $azLoggedIn = [bool]$script:AzLoggedIn

    if ($azLoggedIn) {
        $configuredSubscription = if ($config -and $config.tenant.subscriptionId) { [string]$config.tenant.subscriptionId } else { '' }
        Invoke-Check 'Azure CLI / Subscription' 'Configured subscription is accessible' {
            if (-not $configuredSubscription) { return $null }
            $sub = Invoke-AzJson -Arguments @('account','show','--subscription',$configuredSubscription,'-o','json')
            if ($sub) { "$($sub.name) ($($sub.id))" }
        } "Run: az account set -s YOUR_SUBSCRIPTION_ID"

        if ($configuredSubscription) {
            Invoke-AzText -Arguments @('account','set','--subscription',$configuredSubscription) | Out-Null
        }

        Invoke-Check 'Azure CLI / Subscription' 'Microsoft Graph token can be acquired' {
            $token = Get-M365GraphToken
            if ($token) { 'Graph token acquired from Azure CLI context' }
        } "Run az login again using the target tenant admin account."

        Write-Section 'Azure Resource Providers'
        foreach ($provider in (Get-RequiredProviders -Config $config)) {
            Invoke-Check 'Azure Resource Providers' $provider {
                $state = Invoke-AzText -Arguments @('provider','show','--namespace',$provider,'--query','registrationState','-o','tsv')
                if ($state -eq 'Registered') {
                    "$provider is Registered"
                } elseif ($RegisterProviders) {
                    Write-Host "    Registering $provider and waiting for completion..." -ForegroundColor DarkYellow
                    Invoke-AzText -Arguments @('provider','register','--namespace',$provider,'--wait','--only-show-errors') | Out-Null
                    $state = Invoke-AzText -Arguments @('provider','show','--namespace',$provider,'--query','registrationState','-o','tsv')
                    if ($state -eq 'Registered') { "$provider is Registered" }
                }
            } "Run: az provider register --namespace $provider --wait"
        }

        Write-Section 'Azure OpenAI'
        $selectedLocation = if ($config -and $config.tenant.location) { [string]$config.tenant.location } else { 'eastus2' }
        $selectedModel = if ($config -and $config.infrastructure.openAiModel) { [string]$config.infrastructure.openAiModel } else { 'gpt-4o-mini' }

        Invoke-Check 'Azure OpenAI' "$selectedModel available in $selectedLocation" {
            $model = Invoke-AzText -Arguments @(
                'cognitiveservices','model','list',
                '-l',$selectedLocation,
                '--query',"[?model.name=='$selectedModel'].model.name | [0]",
                '-o','tsv'
            )
            if ($model) { "$selectedModel in $selectedLocation" }
        } "Change infrastructure.openAiModel or tenant.location in config\agents.json."

        Invoke-Check 'Azure OpenAI' "OpenAI quota visible in $selectedLocation" {
            $usage = Invoke-AzJson -Arguments @('cognitiveservices','usage','list','-l',$selectedLocation,'-o','json')
            if ($usage) { "Usage records: $(@($usage).Count)" }
        } "The account needs permissions to read Cognitive Services usage in the subscription." -WarningOnly

        Write-Section 'Microsoft 365 Tenant'
        $agentCount = if ($config -and $config.agents) { @($config.agents).Count } else { 0 }
        $copilotCount = if ($config -and $config.agents) { @($config.agents | Where-Object { $_.copilotLicense }).Count } else { 0 }

        Invoke-Check 'Microsoft 365 Tenant' "M365 licenses available (agents: $agentCount)" {
            $token = Get-M365GraphToken
            if (-not $token) { return $null }
            $headers = @{ Authorization = "Bearer $token" }
            $skus = (Invoke-RestMethod 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $headers -ErrorAction Stop).value
            $eligible = @($skus | Where-Object { $_.skuPartNumber -match 'E[357]|SPE_|ENTERPRISEP|EMSPREMIUM|M365_' })
            if ($eligible.Count -gt 0) {
                $best = $eligible | Sort-Object { $_.prepaidUnits.enabled - $_.consumedUnits } -Descending | Select-Object -First 1
                $available = [int]$best.prepaidUnits.enabled - [int]$best.consumedUnits
                "$($best.skuPartNumber): $available/$($best.prepaidUnits.enabled) available"
            }
        } "Ensure Microsoft 365 E3/E5/E7 or equivalent licenses exist for the lab agents."

        if ($copilotCount -gt 0) {
            Invoke-Check 'Microsoft 365 Tenant' "Copilot licenses available or assignable (agents: $copilotCount)" {
                $token = Get-M365GraphToken
                if (-not $token) { return $null }
                $headers = @{ Authorization = "Bearer $token" }
                $skus = (Invoke-RestMethod 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $headers -ErrorAction Stop).value
                $copilot = @($skus | Where-Object { $_.skuPartNumber -match 'Copilot|M365_COPILOT|MICROSOFT_365_COPILOT' })
                if ($copilot.Count -gt 0) {
                    $available = 0
                    foreach ($sku in $copilot) {
                        $available += ([int]$sku.prepaidUnits.enabled - [int]$sku.consumedUnits)
                    }
                    if ($available -ge $copilotCount) {
                        "Copilot SKU(s): $available available"
                    }
                }
            } "Copilot licenses are optional for base install, but required for Copilot personas." -WarningOnly
        }

        Invoke-Check 'Microsoft 365 Tenant' 'Deploying user has admin directory role' {
            $token = Get-M365GraphToken
            if (-not $token) { return $null }
            $headers = @{ Authorization = "Bearer $token" }
            $roles = (Invoke-RestMethod 'https://graph.microsoft.com/v1.0/me/memberOf' -Headers $headers -ErrorAction Stop).value
            $adminRoles = @($roles | Where-Object {
                $_.'@odata.type' -eq '#microsoft.graph.directoryRole' -and
                $_.displayName -match 'Global Administrator|Privileged Role Administrator'
            })
            if ($adminRoles.Count -gt 0) { ($adminRoles.displayName -join ', ') }
        } "Use a Global Administrator or Privileged Role Administrator account for deployment."

        Invoke-Check 'Microsoft 365 Tenant' 'Security and Compliance PowerShell can be loaded' {
            Import-Module ExchangeOnlineManagement -ErrorAction Stop
            $cmd = Get-Command Connect-IPPSSession -ErrorAction Stop
            if ($cmd) { 'Connect-IPPSSession is available for DLP/IRM/Sensitivity Label steps' }
        } "Install ExchangeOnlineManagement and run Connect-IPPSSession before DLP/IRM steps."
    } else {
        foreach ($name in @(
            'Configured subscription is accessible',
            'Microsoft Graph token can be acquired',
            'Azure resource providers',
            'Azure OpenAI model availability',
            'M365 licenses',
            'Admin role'
        )) {
            Add-CheckResult -Category 'Cloud Checks' -Name $name -Status 'Skip' -Detail 'Skipped because Azure CLI is not logged in.'
        }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
$failed = @($script:Checks | Where-Object Status -eq 'Fail')
$warnings = @($script:Checks | Where-Object Status -eq 'Warn')
$skipped = @($script:Checks | Where-Object Status -eq 'Skip')
$passed = @($script:Checks | Where-Object Status -eq 'Pass')
$allPassed = ($failed.Count -eq 0)

if ($allPassed) {
    Write-Host "  READY ($($passed.Count) passed, $($warnings.Count) warning(s), $($skipped.Count) skipped)" -ForegroundColor Green
} else {
    Write-Host "  NOT READY ($($failed.Count) failed, $($warnings.Count) warning(s), $($skipped.Count) skipped)" -ForegroundColor Red
    Write-Host "  Fix failed checks before running Install-ClaudIA.ps1." -ForegroundColor Yellow
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$result = [PSCustomObject][ordered]@{
    AllPassed = $allPassed
    PassedCount = $passed.Count
    FailedCount = $failed.Count
    WarningCount = $warnings.Count
    SkippedCount = $skipped.Count
    Results = @($script:Checks.ToArray())
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    return $result
}
