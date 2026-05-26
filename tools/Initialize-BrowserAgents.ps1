<#PSScriptInfo

.VERSION 1.0.0

.GUID b01e73f5-62c7-4384-b041-8ba10e92f447

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
Initialize and validate BrowserAgent sessions for one or more M365 personas

.RELEASENOTES
Initial version metadata for Initialize and validate BrowserAgent sessions for one or more M365 personas.

#>
<#
.SYNOPSIS
    Initialize and validate BrowserAgent sessions for one or more M365 personas.
.DESCRIPTION
    For each selected agent, this script can capture or refresh the browser
    session state, then validates access to individual web services such as
    Office/M365, OWA, Copilot/Copilot Chat, and Teams.
.EXAMPLE
    .\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma
.EXAMPLE
    .\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma,ana.rodriguez -RefreshAuth -Services office,owa,copilot
.EXAMPLE
    .\tools\Initialize-BrowserAgents.ps1 -All -Services office,owa -SkipAuth
#>
[CmdletBinding()]
param(
    [string[]]$Agents,
    [switch]$All,
    [string[]]$Services = @('office','owa','copilot','teams'),
    [switch]$RefreshAuth,
    [switch]$SkipAuth,
    [switch]$Azure,
    [switch]$ContinueOnFailure,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$BrowserAgentsPath = (Join-Path $PSScriptRoot '..\BrowserAgents'),
    [string]$ResultsPath = (Join-Path $PSScriptRoot '..\BrowserAgents\test-results\preflight')
)

$ErrorActionPreference = 'Stop'

function Resolve-NodeCommand {
    param([string]$Name)
    $nodePath = 'C:\Program Files\nodejs'
    if (Test-Path -LiteralPath $nodePath) {
        $env:PATH = "$nodePath;$env:PATH"
    }
    $candidate = Join-Path $nodePath "$Name.cmd"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $Name
}

function Get-AgentSecretName {
    param($Agent)
    if ($Agent.keyVaultSecretName) { return [string]$Agent.keyVaultSecretName }
    return ([string]$Agent.sam).Replace('.', '-')
}

function Get-KeyVaultNameFromConfig {
    param($Config)
    if ($Config.browserAgents -and $Config.browserAgents.keyVaultName) { return [string]$Config.browserAgents.keyVaultName }
    if ($Config.infrastructure -and $Config.infrastructure.keyVaultName) { return [string]$Config.infrastructure.keyVaultName }
    if ($Config.adx -and $Config.adx.keyVaultName) { return [string]$Config.adx.keyVaultName }
    return ''
}

function Get-AgentUpn {
    param($Agent, [string]$Domain)
    if ($Agent.userPrincipalName) { return [string]$Agent.userPrincipalName }
    if ($Agent.upn) { return [string]$Agent.upn }
    if ("$($Agent.sam)" -match '@') { return [string]$Agent.sam }
    if (-not $Domain) { throw "Tenant domain is required to build the UPN for '$($Agent.sam)'." }
    return "$($Agent.sam)@$Domain"
}

function Invoke-BrowserAgentAuthCapture {
    param(
        $Agent,
        [string]$KeyVaultName,
        [string]$StorageState,
        [string]$BrowserAgentsPath,
        [string]$Npx
    )
    $secretName = Get-AgentSecretName -Agent $Agent
    $password = az keyvault secret show --vault-name $KeyVaultName --name $secretName --query value -o tsv 2>$null
    if (-not $password) { throw "Secret '$secretName' is empty or could not be read from Key Vault '$KeyVaultName'." }

    $env:BROWSER_AGENT_PERSONA = [string]$Agent.sam
    $env:BROWSER_AGENT_UPN = [string]$Agent.userPrincipalName
    $env:BROWSER_AGENT_DISPLAY_NAME = [string]$Agent.displayName
    $env:BROWSER_AGENT_STORAGE_STATE = $StorageState
    $env:BROWSER_AGENT_PASSWORD = $password
    try {
        Push-Location $BrowserAgentsPath
        & $Npx playwright test tests/auth.setup.spec.js --project=chromium --headed
        if ($LASTEXITCODE -ne 0) { throw "Auth capture failed with exit code $LASTEXITCODE." }
    }
    finally {
        $env:BROWSER_AGENT_PASSWORD = $null
        Pop-Location
    }
}

function Invoke-BrowserAgentPreflight {
    param(
        $Agent,
        [string]$StorageState,
        [string]$ServicesText,
        [string]$ResultFile,
        [string]$BrowserAgentsPath,
        [string]$Npx,
        [switch]$Azure
    )

    $env:BROWSER_AGENT_PERSONA = [string]$Agent.sam
    $env:BROWSER_AGENT_UPN = [string]$Agent.userPrincipalName
    $env:BROWSER_AGENT_DISPLAY_NAME = [string]$Agent.displayName
    $env:BROWSER_AGENT_STORAGE_STATE = $StorageState
    $env:BROWSER_AGENT_PREFLIGHT_SERVICES = $ServicesText
    $env:BROWSER_AGENT_PREFLIGHT_RESULT = $ResultFile
    Push-Location $BrowserAgentsPath
    try {
        if ($Azure) {
            & $Npx playwright test tests/preflight.spec.js -c playwright.azure.config.js | ForEach-Object { Write-Host $_ }
        } else {
            & $Npx playwright test tests/preflight.spec.js --project=chromium | ForEach-Object { Write-Host $_ }
        }
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$tenantDomain = [string]$config.tenant.domain
$allAgents = @($config.agents | Where-Object { $_.sam } | ForEach-Object {
    $_ | Add-Member -NotePropertyName userPrincipalName -NotePropertyValue (Get-AgentUpn -Agent $_ -Domain $tenantDomain) -Force
    $_
})
if (-not $All) {
    if (-not $Agents -or $Agents.Count -eq 0) { throw "Pass -Agents or use -All." }
    $wanted = @{}
    foreach ($item in $Agents) { $wanted[$item.ToLowerInvariant()] = $true }
    $allAgents = @($allAgents | Where-Object {
        $wanted.ContainsKey(([string]$_.sam).ToLowerInvariant()) -or
        $wanted.ContainsKey(([string]$_.userPrincipalName).ToLowerInvariant()) -or
        ($_.displayName -and $wanted.ContainsKey(([string]$_.displayName).ToLowerInvariant()))
    })
}
if (-not $allAgents -or $allAgents.Count -eq 0) { throw "No BrowserAgent users selected." }

$kvName = Get-KeyVaultNameFromConfig -Config $config
if (-not $kvName -and -not $SkipAuth) { throw "Key Vault name not found in config." }

$npm = Resolve-NodeCommand -Name 'npm'
$npx = Resolve-NodeCommand -Name 'npx'

if (-not (Test-Path -LiteralPath (Join-Path $BrowserAgentsPath 'node_modules'))) {
    Write-Host "Installing BrowserAgents npm dependencies..." -ForegroundColor Cyan
    Push-Location $BrowserAgentsPath
    try {
        & $npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $ResultsPath)) {
    New-Item -Path $ResultsPath -ItemType Directory -Force | Out-Null
}

$servicesText = (($Services -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) -join ','
if (-not $servicesText) { throw "No services selected." }

Write-Host "=== BrowserAgent Initialization ===" -ForegroundColor Cyan
Write-Host "  Agents:   $($allAgents.Count)"
Write-Host "  Services: $servicesText"
Write-Host "  Mode:     $(if ($Azure) { 'Azure Playwright Workspace' } else { 'local browser' })"
Write-Host ""

$summary = @()
foreach ($agent in $allAgents) {
    $sam = [string]$agent.sam
    $storageState = ".auth/$sam.json"
    $storageStatePath = Join-Path $BrowserAgentsPath $storageState
    $resultFile = Join-Path $ResultsPath "$sam.json"
    $status = 'pending'
    $comment = ''
    $serviceStatuses = @{}

    Write-Host "[$sam] $($agent.displayName) <$($agent.userPrincipalName)>" -ForegroundColor Cyan
    try {
        if (-not $SkipAuth -and ($RefreshAuth -or -not (Test-Path -LiteralPath $storageStatePath))) {
            if (Test-Path -LiteralPath $storageStatePath) {
                Remove-Item -LiteralPath $storageStatePath -Force
            }
            Write-Host "  Capturing browser session..." -ForegroundColor Gray
            Invoke-BrowserAgentAuthCapture -Agent $agent -KeyVaultName $kvName -StorageState $storageState -BrowserAgentsPath $BrowserAgentsPath -Npx $npx
        } elseif (Test-Path -LiteralPath $storageStatePath) {
            Write-Host "  Existing browser session found." -ForegroundColor Gray
        } else {
            throw "Browser session state '$storageState' does not exist. Run without -SkipAuth or use -RefreshAuth."
        }

        if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force }
        Write-Host "  Validating web services..." -ForegroundColor Gray
        $exitCode = Invoke-BrowserAgentPreflight -Agent $agent -StorageState $storageState -ServicesText $servicesText -ResultFile $resultFile -BrowserAgentsPath $BrowserAgentsPath -Npx $npx -Azure:$Azure
        if (Test-Path -LiteralPath $resultFile) {
            $preflight = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            foreach ($r in @($preflight.results)) {
                $serviceStatuses[$r.service] = $r.status
            }
            $status = $preflight.status
            if ($exitCode -ne 0 -and $status -eq 'success') { $status = 'failed' }
            $failed = @($preflight.results | Where-Object { $_.status -eq 'failed' })
            if ($failed.Count -gt 0) {
                $comment = (($failed | ForEach-Object { "$($_.service): $($_.comment)" }) -join ' | ')
            }
        } else {
            $status = if ($exitCode -eq 0) { 'success' } else { 'failed' }
            if ($exitCode -ne 0) { $comment = "Preflight failed and did not produce a result file." }
        }
    }
    catch {
        $status = 'failed'
        $comment = $_.Exception.Message
        Write-Host "  [FAIL] $comment" -ForegroundColor Red
    }

    foreach ($service in @($servicesText -split ',')) {
        if (-not $serviceStatuses.ContainsKey($service)) { $serviceStatuses[$service] = if ($status -eq 'failed') { 'failed' } else { 'skipped' } }
    }

    $row = [ordered]@{
        Agent = $sam
        UPN = [string]$agent.userPrincipalName
        DisplayName = [string]$agent.displayName
        Status = $status
    }
    foreach ($service in @($servicesText -split ',')) {
        $row[$service] = $serviceStatuses[$service]
    }
    $row['Comments'] = $comment
    $summary += [PSCustomObject]$row

    $color = if ($status -eq 'success') { 'Green' } else { 'Red' }
    Write-Host "  [$($status.ToUpperInvariant())]" -ForegroundColor $color
    if ($comment) { Write-Host "  $comment" -ForegroundColor Yellow }
    if (-not $ContinueOnFailure -and $status -eq 'failed') { break }
}

Write-Host ""
Write-Host "=== BrowserAgent Initialization Results ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize



