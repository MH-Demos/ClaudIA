<#
.SYNOPSIS
    Publishes the ClaudIA Teams Bot expansion pack configuration.
.DESCRIPTION
    Creates pack-owned configuration files for ClaudIA so the Teams bot can
    operate against a selected subscription/resource set without modifying the
    main config\Installation_definitions.json.
.EXAMPLE
    .\tools\Install-ClaudiaTeamsBotExpansionPack.ps1
.EXAMPLE
    .\tools\Install-ClaudiaTeamsBotExpansionPack.ps1 -SubscriptionId '<sub>' -ResourceGroup 'claudia-agents' -AutomationAccountName 'claudia-agents'
.EXAMPLE
    .\tools\Install-ClaudiaTeamsBotExpansionPack.ps1 -SubscriptionId '<automation-sub>' -AdxSubscriptionId '<adx-sub>' -BrowserAgentsSubscriptionId '<browser-sub>'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$PackConfigPath = (Join-Path $PSScriptRoot '..\expansion-packs\claudia-teams-bot\config\claudia.pack.json'),
    [string]$PackAgentsPath = (Join-Path $PSScriptRoot '..\expansion-packs\claudia-teams-bot\config\agents.json'),
    [string]$PackInstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\expansion-packs\claudia-teams-bot\config\Installation_definitions.json'),
    [string]$RuntimeConfigPath = (Join-Path $PSScriptRoot '..\TeamsBot\config\claudia.runtime.json'),
    [string]$SubscriptionId,
    [string]$AdxSubscriptionId,
    [string]$BrowserAgentsSubscriptionId,
    [string]$ResourceGroup,
    [string]$AutomationAccountName,
    [string]$AllowedUsers,
    [string]$MicrosoftAppId,
    [string]$MicrosoftAppTenantId,
    [string]$BotHostname
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function ConvertTo-AbsolutePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Value
    )

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Value))
}

function Set-Property {
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

function Clone-JsonObject {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function Resolve-AllowedUsers {
    param($PackConfig, [string]$Override)
    if ($Override) {
        return @($Override -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($PackConfig.bot -and $PackConfig.bot.allowedUsers) {
        return @($PackConfig.bot.allowedUsers)
    }
    return @()
}

if (-not (Test-Path -LiteralPath $PackConfigPath)) {
    throw "ClaudIA pack config not found: $PackConfigPath"
}

$packConfig = Get-Content -LiteralPath $PackConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = Clone-JsonObject -Value $effective.Config
$definitions = if ($effective.Definitions) {
    Clone-JsonObject -Value $effective.Definitions
} else {
    [PSCustomObject][ordered]@{
        schemaVersion = '1.0'
        runId = "claudia-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o')
        sourceConfigPath = $PackAgentsPath
        tenant = [ordered]@{}
        infrastructure = [ordered]@{}
        agents = @($config.agents)
    }
}

$finalSubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { [string]$config.tenant.subscriptionId }
$finalAdxSubscriptionId = if ($AdxSubscriptionId) { $AdxSubscriptionId } elseif ($config.adx -and $config.adx.subscriptionId) { [string]$config.adx.subscriptionId } else { $finalSubscriptionId }
$finalBrowserSubscriptionId = if ($BrowserAgentsSubscriptionId) { $BrowserAgentsSubscriptionId } elseif ($config.browserAgents -and $config.browserAgents.subscriptionId) { [string]$config.browserAgents.subscriptionId } else { $finalSubscriptionId }
$finalResourceGroup = if ($ResourceGroup) { $ResourceGroup } else { [string]$config.infrastructure.resourceGroup }
$finalAutomationAccount = if ($AutomationAccountName) { $AutomationAccountName } else { [string]$config.infrastructure.automationAccountName }

Set-Property -Object $config.tenant -Name subscriptionId -Value $finalSubscriptionId
Set-Property -Object $config.infrastructure -Name resourceGroup -Value $finalResourceGroup
Set-Property -Object $config.infrastructure -Name automationAccountName -Value $finalAutomationAccount
if ($config.adx) {
    Set-Property -Object $config.adx -Name subscriptionId -Value $finalAdxSubscriptionId
}
if ($config.browserAgents) {
    Set-Property -Object $config.browserAgents -Name subscriptionId -Value $finalBrowserSubscriptionId
}

if (-not $definitions.tenant) { Set-Property -Object $definitions -Name tenant -Value ([PSCustomObject]@{}) }
if (-not $definitions.infrastructure) { Set-Property -Object $definitions -Name infrastructure -Value ([PSCustomObject]@{}) }
Set-Property -Object $definitions -Name sourceConfigPath -Value ([System.IO.Path]::GetFullPath($PackAgentsPath))
Set-Property -Object $definitions -Name updatedAt -Value (Get-Date).ToString('o')
Set-Property -Object $definitions.tenant -Name subscriptionId -Value $finalSubscriptionId
Set-Property -Object $definitions.infrastructure -Name resourceGroup -Value $finalResourceGroup
Set-Property -Object $definitions.infrastructure -Name automationAccountName -Value $finalAutomationAccount
if ($definitions.adx) {
    Set-Property -Object $definitions.adx -Name subscriptionId -Value $finalAdxSubscriptionId
}
if ($definitions.browserAgents) {
    Set-Property -Object $definitions.browserAgents -Name subscriptionId -Value $finalBrowserSubscriptionId
} elseif ($config.browserAgents) {
    Set-Property -Object $definitions -Name browserAgents -Value $config.browserAgents
}

$packConfigDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($PackConfigPath))
$runtimeConfig = [PSCustomObject][ordered]@{
    schemaVersion = '1.0'
    expansionPack = 'claudia-teams-bot'
    generatedAt = (Get-Date).ToString('o')
    runtime = [ordered]@{
        configPath = [System.IO.Path]::GetFullPath($PackAgentsPath)
        installationDefinitionsPath = [System.IO.Path]::GetFullPath($PackInstallationDefinitionsPath)
        subscriptionId = $finalSubscriptionId
        adxSubscriptionId = $finalAdxSubscriptionId
        browserAgentsSubscriptionId = $finalBrowserSubscriptionId
        resourceGroup = $finalResourceGroup
        automationAccountName = $finalAutomationAccount
    }
    bot = [ordered]@{
        port = if ($packConfig.bot.port) { [int]$packConfig.bot.port } else { 3978 }
        powershell = if ($packConfig.bot.powershell) { [string]$packConfig.bot.powershell } else { 'pwsh' }
        timeoutSeconds = if ($packConfig.bot.timeoutSeconds) { [int]$packConfig.bot.timeoutSeconds } else { 900 }
        outputMaxChars = if ($packConfig.bot.outputMaxChars) { [int]$packConfig.bot.outputMaxChars } else { 3500 }
        allowedUsers = @(Resolve-AllowedUsers -PackConfig $packConfig -Override $AllowedUsers)
    }
    teamsApp = [ordered]@{
        teamsAppId = if ($packConfig.teamsApp.teamsAppId) { [string]$packConfig.teamsApp.teamsAppId } else { '' }
        microsoftAppId = if ($MicrosoftAppId) { $MicrosoftAppId } elseif ($packConfig.teamsApp.microsoftAppId) { [string]$packConfig.teamsApp.microsoftAppId } else { '' }
        microsoftAppTenantId = if ($MicrosoftAppTenantId) { $MicrosoftAppTenantId } elseif ($packConfig.teamsApp.microsoftAppTenantId) { [string]$packConfig.teamsApp.microsoftAppTenantId } else { '' }
        botHostname = if ($BotHostname) { $BotHostname } elseif ($packConfig.teamsApp.botHostname) { [string]$packConfig.teamsApp.botHostname } else { '' }
    }
}

if ($PSCmdlet.ShouldProcess('ClaudIA Teams Bot expansion pack', 'Publish pack-owned configuration')) {
    Ensure-Directory -Path $PackAgentsPath
    Ensure-Directory -Path $PackInstallationDefinitionsPath
    Ensure-Directory -Path $RuntimeConfigPath

    $config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $PackAgentsPath -Encoding utf8
    $definitions | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $PackInstallationDefinitionsPath -Encoding utf8
    $runtimeConfig | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $RuntimeConfigPath -Encoding utf8
}

Write-Host "=== ClaudIA Teams Bot Expansion Pack ===" -ForegroundColor Cyan
Write-Host "  Pack config:       $([System.IO.Path]::GetFullPath($PackConfigPath))"
Write-Host "  Agents config:     $([System.IO.Path]::GetFullPath($PackAgentsPath))"
Write-Host "  Definitions:       $([System.IO.Path]::GetFullPath($PackInstallationDefinitionsPath))"
Write-Host "  Bot runtime config:$([System.IO.Path]::GetFullPath($RuntimeConfigPath))"
Write-Host "  Subscription:      $finalSubscriptionId"
Write-Host "  ADX subscription:  $finalAdxSubscriptionId"
Write-Host "  Browser sub:       $finalBrowserSubscriptionId"
Write-Host "  Resource group:    $finalResourceGroup"
Write-Host "  Automation:        $finalAutomationAccount"
Write-Host ""
Write-Host "Next: configure TeamsBot\.env with MicrosoftAppId/MicrosoftAppPassword/MicrosoftAppTenantId, then run npm start from TeamsBot." -ForegroundColor Yellow
