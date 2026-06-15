<#PSScriptInfo

.VERSION 1.0.0

.GUID 8c1c2ec1-9d4a-4f73-95d8-6f3b8b1a8e23

.AUTHOR
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Azure NameCollision Reset

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Reset globally-unique resource names in agents.json and Installation_definitions.json so the installer regenerates fresh names on the next run.

.RELEASENOTES
Initial version. Targets Azure OpenAI, Key Vault, ADX cluster, Activity Story Map storage and Function App, and Browser Agents workspace ids.

#>
<#
.SYNOPSIS
    Reset persisted globally-unique resource names before redeploying to a fresh subscription or tenant.

.DESCRIPTION
    Several ClaudIA resources have DNS-global names (Azure OpenAI custom domain, Key Vault,
    Storage Accounts, Function App, ADX cluster). When you redeploy on a new tenant or
    subscription, the persisted names from a previous run will collide globally and
    Install-ClaudIA.ps1 will fail mid-run, leaving orphan billable resources behind.

    This script:
      1. Backs up agents.json and Installation_definitions.json to config\backups\.
      2. Detects if the active az subscription differs from the configured one.
      3. Clears the unique-name fields so Step 4 / Step 7 / Step 8 regenerate fresh,
         deterministic, subscription-seeded names on the next install.

    Fields cleared (and reasons):
      infrastructure.openAiAccountName            DNS global (X.openai.azure.com)
      infrastructure.keyVaultName                 DNS global + 90d soft-delete
      adx.keyVaultName                            mirror of infrastructure.keyVaultName
      adx.clusterName                             DNS global (X.<region>.kusto.windows.net)
      adx.ingestBaseUri / queryBaseUri            derived from cluster name
      activityStoryMap.storageAccountName         DNS global
      activityStoryMap.functionStorageAccountName DNS global
      activityStoryMap.functionAppName            DNS global (X.azurewebsites.net)
      activityStoryMap.staticWebsiteUrl           derived
      activityStoryMap.apiBaseUrl                 derived
      activityStoryMap.launchUrl                  derived
      activityStoryMap.source.clusterName         mirror of adx.clusterName
      browserAgents.workspaceId                   per-subscription guid
      browserAgents.dataplaneUri                  derived from workspaceId
      browserAgents.playwrightServiceUrl          derived from workspaceId

    Fields preserved (not collision-prone):
      tenant.* (you change tenant manually)
      infrastructure.resourceGroup
      infrastructure.automationAccountName  (RG-scoped)
      infrastructure.openAiModel / TPM / fabricEnabled
      adx.databaseName / tableName / mappingName
      browserAgents.workspaceName (gets a new id, name can stay)

.PARAMETER ConfigPath
    Path to agents.json. Defaults to ..\config\agents.json relative to this script.

.PARAMETER InstallationDefinitionsPath
    Path to Installation_definitions.json. Defaults to ..\config\Installation_definitions.json.

.PARAMETER Force
    Reset even when the active az subscription matches the configured one
    (useful after a manual sub wipe).

.PARAMETER WhatIf
    Show what would change without writing the files.

.EXAMPLE
    .\tools\Reset-UniqueNames.ps1 -WhatIf

.EXAMPLE
    .\tools\Reset-UniqueNames.ps1
    # Active sub differs from configured -> backs up + clears unique names.

.EXAMPLE
    .\tools\Reset-UniqueNames.ps1 -Force
    # Force reset even when subs match (e.g. after deleting all resources manually).

.LINK
    .\tools\Test-NameAvailability.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-ActiveAzSubscriptionId {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $out = & az account show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

function Clear-AAProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [string]$EmptyValue = '')
    if (-not $Object) { return $false }
    if ($Object.PSObject.Properties[$Name] -and $Object.$Name -ne $EmptyValue -and $null -ne $Object.$Name) {
        $Object.$Name = $EmptyValue
        return $true
    }
    return $false
}

function Backup-File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path)
    $dst = Join-Path $BackupDir "$name.$stamp.bak$ext"
    Copy-Item -LiteralPath $Path -Destination $dst -Force
    return $dst
}

# ---- load configs ----
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

$defs = $null
if (Test-Path -LiteralPath $InstallationDefinitionsPath) {
    $defs = Get-Content -LiteralPath $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
}

$configuredSub = [string]$config.tenant.subscriptionId
$activeSub = Get-ActiveAzSubscriptionId

Write-Host ''
Write-Host '=== Reset-UniqueNames ==='
Write-Host "  Configured subscription : $configuredSub"
Write-Host "  Active az subscription  : $($activeSub | ForEach-Object { if ($_) { $_ } else { '(not logged in)' } })"

$subMismatch = ($activeSub -and ($activeSub -ne $configuredSub))
if ($subMismatch) {
    Write-Host '  -> Subscription mismatch detected. Reset is REQUIRED.' -ForegroundColor Yellow
} elseif ($Force) {
    Write-Host '  -> Subscription matches but -Force was passed. Reset will proceed.' -ForegroundColor Yellow
} else {
    Write-Host '  -> Subscription matches. Pass -Force to reset anyway.' -ForegroundColor Cyan
    Write-Host ''
    return
}

# ---- compute changes ----
$changes = @()

function Apply-Reset {
    param($Root, [string]$Section, [string]$Field, [string]$EmptyValue = '')
    if (-not $Root) { return }
    $target = if ($Section) { $Root.$Section } else { $Root }
    if (-not $target) { return }
    if (-not $target.PSObject.Properties[$Field]) { return }
    $old = $target.$Field
    if ($null -eq $old -or "$old" -eq $EmptyValue) { return }
    $script:changes += [PSCustomObject]@{
        File = $script:currentFile
        Path = if ($Section) { "$Section.$Field" } else { $Field }
        Old  = "$old"
        New  = $EmptyValue
    }
    $target.$Field = $EmptyValue
}

function Reset-Document {
    param($Root)
    Apply-Reset $Root 'infrastructure'      'openAiAccountName'
    Apply-Reset $Root 'infrastructure'      'keyVaultName'

    Apply-Reset $Root 'adx'                 'keyVaultName'
    Apply-Reset $Root 'adx'                 'clusterName'
    Apply-Reset $Root 'adx'                 'ingestBaseUri'
    Apply-Reset $Root 'adx'                 'queryBaseUri'

    Apply-Reset $Root 'activityStoryMap'    'storageAccountName'
    Apply-Reset $Root 'activityStoryMap'    'functionStorageAccountName'
    Apply-Reset $Root 'activityStoryMap'    'functionAppName'
    Apply-Reset $Root 'activityStoryMap'    'staticWebsiteUrl'
    Apply-Reset $Root 'activityStoryMap'    'apiBaseUrl'
    Apply-Reset $Root 'activityStoryMap'    'launchUrl'

    if ($Root.activityStoryMap -and $Root.activityStoryMap.source) {
        $script:currentSection = 'activityStoryMap.source'
        Apply-Reset $Root.activityStoryMap 'source' 'clusterName'
        $script:currentSection = $null
    }

    Apply-Reset $Root 'browserAgents'       'workspaceId'
    Apply-Reset $Root 'browserAgents'       'dataplaneUri'
    Apply-Reset $Root 'browserAgents'       'playwrightServiceUrl'
}

$script:currentFile = 'agents.json'
Reset-Document -Root $config

if ($defs) {
    $script:currentFile = 'Installation_definitions.json'
    Reset-Document -Root $defs
}

if ($changes.Count -eq 0) {
    Write-Host ''
    Write-Host '  Nothing to reset. All unique-name fields are already empty.' -ForegroundColor Green
    return
}

Write-Host ''
Write-Host "Pending changes ($($changes.Count)):" -ForegroundColor Cyan
$changes | Format-Table File, Path, Old -AutoSize

# ---- write or whatif ----
if ($PSCmdlet.ShouldProcess($ConfigPath, 'Backup and reset unique-name fields')) {
    $backupDir = Join-Path (Split-Path $ConfigPath -Parent) 'backups'
    $cfgBackup = Backup-File -Path $ConfigPath -BackupDir $backupDir
    Write-Host "  Backed up: $cfgBackup" -ForegroundColor DarkGray
    $config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
    Write-Host "  Wrote: $ConfigPath" -ForegroundColor Green
}

if ($defs -and $PSCmdlet.ShouldProcess($InstallationDefinitionsPath, 'Backup and reset unique-name fields')) {
    $backupDir = Join-Path (Split-Path $InstallationDefinitionsPath -Parent) 'backups'
    $defsBackup = Backup-File -Path $InstallationDefinitionsPath -BackupDir $backupDir
    Write-Host "  Backed up: $defsBackup" -ForegroundColor DarkGray
    if ($defs.PSObject.Properties['updatedAt']) {
        $defs.updatedAt = (Get-Date).ToString('o')
    }
    $defs | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $InstallationDefinitionsPath -Encoding utf8
    Write-Host "  Wrote: $InstallationDefinitionsPath" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Verify generated names will be available globally:'
Write-Host '       .\tools\Test-NameAvailability.ps1'
Write-Host '  2. Re-run the wizard (or Install-ClaudIA.ps1) on the fresh subscription.'
Write-Host '     The empty fields will be regenerated as deterministic hashes.'
Write-Host ''
