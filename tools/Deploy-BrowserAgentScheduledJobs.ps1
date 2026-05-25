<#
.SYNOPSIS
    Deploys BrowserAgents as scheduled Azure Container Apps Jobs.
.DESCRIPTION
    Builds the BrowserAgents container image into a private Azure Container
    Registry, creates a Container Apps environment, and creates one scheduled
    job per schedule defined in config\agents.json.

    The container image includes BrowserAgents\.auth session state files so the
    Azure job can run without interactive sign-in. This is intentionally a lab
    shortcut; refresh those sessions regularly and keep the ACR private.
.EXAMPLE
    .\tools\Deploy-BrowserAgentScheduledJobs.ps1 -WhatIf
.EXAMPLE
    .\tools\Deploy-BrowserAgentScheduledJobs.ps1 -Deploy -Services owa,copilot,banking -ExternalRecipient demo.recipient@example.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$SubscriptionId = '',
    [string]$ResourceGroup = '',
    [string]$Location = '',
    [string]$AcrName = '',
    [string]$EnvironmentName = '',
    [string]$ManagedIdentityName = '',
    [string]$JobNamePrefix = 'browseragents',
    [string]$ImageName = 'browseragents',
    [string]$ImageTag = 'latest',
    [string[]]$Agents,
    [string[]]$Services = @('owa','copilot','banking'),
    [string]$ExternalRecipient = 'demo.recipient@example.com',
    [switch]$SendEmail,
    [switch]$Sensitive,
    [string]$Label = 'General',
    [string]$BrowserRegionKey = '',
    [string]$PlaywrightWorkspaceName = '',
    [string]$PlaywrightServiceUrl = '',
    [int]$ReplicaTimeoutSeconds = 3600,
    [double]$Cpu = 2.0,
    [string]$Memory = '4Gi',
    [int]$WeekendActivityPercent = 25,
    [switch]$SkipAgentsMissingAuth,
    [switch]$Deploy
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param([string[]]$Arguments, [switch]$AllowEmpty)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output | Out-String) }
    $text = ($output | Out-String).Trim()
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch {
        if ($AllowEmpty) { return $null }
        throw "Azure CLI did not return JSON for: az $($Arguments -join ' ')`n$text"
    }
}

function Invoke-AzCli {
    param([string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output | Out-String) }
    return ($output | Out-String).Trim()
}

function Get-AzCliJsonOrNull {
    param([string[]]$Arguments)
    try { return Invoke-AzCliJson -Arguments $Arguments -AllowEmpty }
    catch { return $null }
}

function Ensure-RoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$Role,
        [string]$Scope
    )
    try {
        Invoke-AzCli -Arguments @(
            'role','assignment','create',
            '--assignee-object-id',$PrincipalId,
            '--assignee-principal-type','ServicePrincipal',
            '--role',$Role,
            '--scope',$Scope,
            '-o','none'
        ) | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'RoleAssignmentExists|already exists') { throw }
    }
}

function New-DeterministicName {
    param([string]$Prefix, [string]$Seed, [int]$MaxLength = 50)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hash = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })
    $base = ($Prefix.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    $name = "$base-$hash"
    if ($name.Length -gt $MaxLength) { $name = $name.Substring(0, $MaxLength).Trim('-') }
    return $name
}

function Get-UtcCron {
    param($Schedule)
    $tzId = if ($Schedule.timezone) { [string]$Schedule.timezone } else { [System.TimeZoneInfo]::Local.Id }
    try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId) }
    catch { $tz = [System.TimeZoneInfo]::Utc; $tzId = 'UTC' }

    $today = Get-Date
    $localUnspecified = [DateTime]::SpecifyKind(
        (Get-Date -Year $today.Year -Month $today.Month -Day $today.Day -Hour ([int]$Schedule.hour) -Minute ([int]$Schedule.minute) -Second 0),
        [DateTimeKind]::Unspecified
    )
    $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($localUnspecified, $tz)
    [PSCustomObject]@{
        Name = [string]$Schedule.name
        LocalTime = ('{0:D2}:{1:D2} {2}' -f [int]$Schedule.hour, [int]$Schedule.minute, $tzId)
        UtcTime = $utc.ToString('HH:mm')
        Cron = ('{0} {1} * * *' -f $utc.Minute, $utc.Hour)
    }
}

function Get-AgentList {
    param($Config, [string[]]$Selected)
    $domain = [string]$Config.tenant.domain
    $all = @($Config.agents | Where-Object { $_.sam } | ForEach-Object {
        if (-not $_.userPrincipalName) {
            $_ | Add-Member -NotePropertyName userPrincipalName -NotePropertyValue "$($_.sam)@$domain" -Force
        }
        $_
    })
    if (-not $Selected -or $Selected.Count -eq 0) { return $all }
    $wanted = @{}
    foreach ($item in $Selected) { $wanted[$item.ToLowerInvariant()] = $true }
    return @($all | Where-Object {
        $wanted.ContainsKey(([string]$_.sam).ToLowerInvariant()) -or
        $wanted.ContainsKey(([string]$_.userPrincipalName).ToLowerInvariant()) -or
        $wanted.ContainsKey(([string]$_.displayName).ToLowerInvariant())
    })
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$browserRoot = Join-Path $repoRoot 'BrowserAgents'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if (-not $SubscriptionId) { $SubscriptionId = $config.browserAgents.subscriptionId ?? $config.tenant.subscriptionId }
if (-not $ResourceGroup) { $ResourceGroup = $config.browserAgents.resourceGroup ?? $config.infrastructure.resourceGroup }
if (-not $Location) { $Location = $config.browserAgents.location ?? $config.tenant.location }
if (-not $AcrName) { $AcrName = (New-DeterministicName -Prefix 'acr-browseragents' -Seed "$SubscriptionId/$ResourceGroup" -MaxLength 50) -replace '-', '' }
if (-not $EnvironmentName) { $EnvironmentName = New-DeterministicName -Prefix 'cae-browseragents' -Seed "$SubscriptionId/$ResourceGroup" }
if (-not $ManagedIdentityName) { $ManagedIdentityName = New-DeterministicName -Prefix 'id-browseragents' -Seed "$SubscriptionId/$ResourceGroup" }

$selectedAgents = Get-AgentList -Config $config -Selected $Agents
if (-not $selectedAgents -or $selectedAgents.Count -eq 0) { throw 'No BrowserAgents selected.' }

$missingAuth = @($selectedAgents | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $browserRoot ".auth\$($_.sam).json"))
})
if ($missingAuth.Count -gt 0) {
    $names = ($missingAuth.sam -join ', ')
    Write-Warning "Missing BrowserAgent session state for: $names. Run .\tools\Initialize-BrowserAgents.ps1 first."
    if ($SkipAgentsMissingAuth) {
        $selectedAgents = @($selectedAgents | Where-Object { $missingAuth.sam -notcontains $_.sam })
    } elseif ($Deploy) {
        throw "Cannot deploy all selected agents because BrowserAgent session state is missing for: $names."
    }
}
if (-not $selectedAgents -or $selectedAgents.Count -eq 0) { throw 'No BrowserAgents selected after auth-state validation.' }

if (-not $config.browserAgents.playwrightServiceUrl) {
    throw 'browserAgents.playwrightServiceUrl is required in config\agents.json.'
}
if (-not $config.adx.clientId -or -not $config.adx.clientSecretName -or -not $config.adx.keyVaultName) {
    throw 'ADX clientId, clientSecretName, and keyVaultName are required in config\agents.json.'
}

$servicesText = (($Services -join ',') -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }) -join ','
$agentsText = ($selectedAgents.sam -join ',')
$schedulePlans = @($config.schedules | ForEach-Object { Get-UtcCron -Schedule $_ })

$activeBrowserWorkspace = $null
if ($BrowserRegionKey) {
    $activeBrowserWorkspace = @($config.browserAgents.regionalWorkspaces | Where-Object {
        ([string]$_.key).Equals($BrowserRegionKey, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if (-not $activeBrowserWorkspace) {
        throw "Browser region '$BrowserRegionKey' was not found in browserAgents.regionalWorkspaces."
    }
}
if (-not $activeBrowserWorkspace) { $activeBrowserWorkspace = $config.browserAgents }
if (-not $PlaywrightWorkspaceName) { $PlaywrightWorkspaceName = [string]$activeBrowserWorkspace.workspaceName }
if (-not $PlaywrightServiceUrl) { $PlaywrightServiceUrl = [string]$activeBrowserWorkspace.playwrightServiceUrl }
if (-not $PlaywrightWorkspaceName -or -not $PlaywrightServiceUrl) {
    throw 'Playwright workspace name and service URL are required. Use -BrowserRegionKey or pass -PlaywrightWorkspaceName/-PlaywrightServiceUrl.'
}

Write-Host '=== Deploy BrowserAgent Scheduled Jobs ===' -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  Resource RG:  $ResourceGroup"
Write-Host "  Location:     $Location"
Write-Host "  Browser key:  $(if ($BrowserRegionKey) { $BrowserRegionKey } else { 'default' })"
Write-Host "  PW Workspace: $PlaywrightWorkspaceName"
Write-Host "  ACR:          $AcrName"
Write-Host "  Environment:  $EnvironmentName"
Write-Host "  Identity:     $ManagedIdentityName"
Write-Host "  Agents:       $($selectedAgents.Count)"
Write-Host "  Services:     $servicesText"
Write-Host "  External:     $ExternalRecipient"
Write-Host ''
Write-Host 'Schedules converted to UTC cron:' -ForegroundColor Yellow
$schedulePlans | Format-Table Name,LocalTime,UtcTime,Cron -AutoSize

if (-not $Deploy) {
    Write-Host ''
    Write-Host 'Plan only. Re-run with -Deploy to create/update Azure resources.' -ForegroundColor Yellow
    return
}

& az account set --subscription $SubscriptionId

foreach ($namespace in @('Microsoft.App','Microsoft.ContainerRegistry','Microsoft.ManagedIdentity','Microsoft.OperationalInsights')) {
    Write-Host "Registering provider $namespace..."
    Invoke-AzCli -Arguments @('provider','register','--namespace',$namespace,'--only-show-errors') | Out-Null
}

if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Create/update resource group')) {
    $rg = Get-AzCliJsonOrNull -Arguments @('group','show','-n',$ResourceGroup,'-o','json')
    if ($rg) {
        Write-Host "Resource group exists in $($rg.location); new resources will use $Location where supported."
    } else {
        Invoke-AzCliJson -Arguments @('group','create','-n',$ResourceGroup,'-l',$Location,'-o','json') | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($AcrName, 'Create/update Azure Container Registry')) {
    $acr = Get-AzCliJsonOrNull -Arguments @('acr','show','-n',$AcrName,'-g',$ResourceGroup,'-o','json')
    if (-not $acr) {
        $acr = Invoke-AzCliJson -Arguments @('acr','create','-n',$AcrName,'-g',$ResourceGroup,'--sku','Basic','--admin-enabled','false','-o','json')
    }
}

$loginServer = Invoke-AzCli -Arguments @('acr','show','-n',$AcrName,'-g',$ResourceGroup,'--query','loginServer','-o','tsv')
$image = "$loginServer/$ImageName`:$ImageTag"

if ($PSCmdlet.ShouldProcess($image, 'Build and push BrowserAgent image')) {
    Invoke-AzCli -Arguments @('acr','build','-r',$AcrName,'-t',"$ImageName`:$ImageTag",'-f','BrowserAgents/Dockerfile','.')
}

if ($PSCmdlet.ShouldProcess($ManagedIdentityName, 'Create/update user-assigned managed identity')) {
    $identity = Get-AzCliJsonOrNull -Arguments @('identity','show','-n',$ManagedIdentityName,'-g',$ResourceGroup,'-o','json')
    if (-not $identity) {
        $identity = Invoke-AzCliJson -Arguments @('identity','create','-n',$ManagedIdentityName,'-g',$ResourceGroup,'-l',$Location,'-o','json')
    }
}
$identityId = $identity.id
$identityClientId = $identity.clientId
$identityPrincipalId = $identity.principalId

$acrId = Invoke-AzCli -Arguments @('acr','show','-n',$AcrName,'-g',$ResourceGroup,'--query','id','-o','tsv')
Ensure-RoleAssignment -PrincipalId $identityPrincipalId -Role 'AcrPull' -Scope $acrId

$playwrightScope = "/subscriptions/$SubscriptionId/resourceGroups/$($config.browserAgents.resourceGroup)/providers/Microsoft.LoadTestService/playwrightWorkspaces/$PlaywrightWorkspaceName"
Ensure-RoleAssignment -PrincipalId $identityPrincipalId -Role 'Playwright Workspace Contributor' -Scope $playwrightScope

if ($PSCmdlet.ShouldProcess($EnvironmentName, 'Create/update Container Apps environment')) {
    $env = Get-AzCliJsonOrNull -Arguments @('containerapp','env','show','-n',$EnvironmentName,'-g',$ResourceGroup,'-o','json')
    if (-not $env) {
        Invoke-AzCli -Arguments @(
            'containerapp','env','create',
            '-n',$EnvironmentName,
            '-g',$ResourceGroup,
            '-l',$Location,
            '--logs-destination','none',
            '-o','none'
        ) | Out-Null
    } elseif ($env.properties.appLogsConfiguration.destination -eq 'log-analytics') {
        Write-Warning "Container Apps environment '$EnvironmentName' uses Log Analytics platform logs. Delete/recreate it with --logs-destination none if strict no-LA operation is required."
    }
}

$adxSecret = Invoke-AzCli -Arguments @(
    'keyvault','secret','show',
    '--vault-name', $config.adx.keyVaultName,
    '--name', $config.adx.clientSecretName,
    '--query', 'value',
    '-o', 'tsv'
)
if (-not $adxSecret) { throw "Could not read ADX client secret '$($config.adx.clientSecretName)' from Key Vault '$($config.adx.keyVaultName)'." }

$baseEnv = @(
    "PLAYWRIGHT_SERVICE_URL=$PlaywrightServiceUrl",
    "AZURE_CLIENT_ID=$identityClientId",
    "BROWSER_AGENT_CONFIG_PATH=/app/config/agents.json",
    "BROWSER_AGENT_RUN_AGENTS=$agentsText",
    "BROWSER_AGENT_SERVICES=$servicesText",
    "BROWSER_AGENT_EXTERNAL_RECIPIENT=$ExternalRecipient",
    "BROWSER_AGENT_SEND_EMAIL=$([string]([bool]$SendEmail).ToString().ToLowerInvariant())",
    "BROWSER_AGENT_INCLUDE_SENSITIVE=$([string]([bool]$Sensitive).ToString().ToLowerInvariant())",
    "BROWSER_AGENT_EMAIL_LABEL=$Label",
    "BROWSER_AGENT_CONTINUE_ON_FAILURE=true",
    "BROWSER_AGENT_WEEKEND_ACTIVITY_PERCENT=$WeekendActivityPercent",
    "BROWSER_AGENT_ADX_CLIENT_SECRET=secretref:adxsecret"
)

foreach ($schedule in $schedulePlans) {
    $jobName = (($JobNamePrefix + '-' + $schedule.Name).ToLowerInvariant() -replace '[^a-z0-9-]', '-')
    if ($jobName.Length -gt 32) { $jobName = $jobName.Substring(0, 32).Trim('-') }
    Write-Host ''
    Write-Host "Creating/updating job $jobName ($($schedule.Cron) UTC)..." -ForegroundColor Cyan

    $existing = Get-AzCliJsonOrNull -Arguments @('containerapp','job','show','-n',$jobName,'-g',$ResourceGroup,'-o','json')
    if (-not $existing) {
        $createArgs = @(
            'containerapp','job','create',
            '-n',$jobName,
            '-g',$ResourceGroup,
            '--environment',$EnvironmentName,
            '--trigger-type','Schedule',
            '--cron-expression',$schedule.Cron,
            '--replica-timeout',"$ReplicaTimeoutSeconds",
            '--replica-retry-limit','0',
            '--replica-completion-count','1',
            '--parallelism','1',
            '--image',$image,
            '--cpu',"$Cpu",
            '--memory',$Memory,
            '--registry-server',$loginServer,
            '--registry-identity',$identityId,
            '--mi-user-assigned',$identityId,
            '--secrets',"adxsecret=$adxSecret",
            '--env-vars'
        ) + $baseEnv
        $createArgs += @('-o','none')
        Invoke-AzCli -Arguments $createArgs | Out-Null
    } else {
        Invoke-AzCli -Arguments @('containerapp','job','secret','set','-n',$jobName,'-g',$ResourceGroup,'--secrets',"adxsecret=$adxSecret") | Out-Null
        $updateArgs = @(
            'containerapp','job','update',
            '-n',$jobName,
            '-g',$ResourceGroup,
            '--image',$image,
            '--cron-expression',$schedule.Cron,
            '--replica-timeout',"$ReplicaTimeoutSeconds",
            '--parallelism','1',
            '--set-env-vars'
        ) + $baseEnv
        $updateArgs += @('-o','none')
        Invoke-AzCli -Arguments $updateArgs | Out-Null
    }
}

Write-Host ''
Write-Host 'BrowserAgent scheduled jobs deployed.' -ForegroundColor Green
Write-Host 'Use az containerapp job execution list/show to review automatic runs.' -ForegroundColor Yellow
