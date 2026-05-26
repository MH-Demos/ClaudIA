<#PSScriptInfo

.VERSION 1.0.0

.GUID 39dfae26-9172-49a1-b250-682677d032c6

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
Add existing Entra ID users as storyline expansion agents without duplicates

.RELEASENOTES
Initial version metadata for Add existing Entra ID users as storyline expansion agents without duplicates.

#>
<#
.SYNOPSIS
    Add existing Entra ID users as storyline expansion agents without duplicates.
.DESCRIPTION
    Reads config/agents.json and Storyline/profiles.md, lists tenant users that are
    not already configured as agents, and appends selected users to agents.json.

    This script can also act as an "expansion pack installer": reset selected
    users to a generated/shared password, store one Key Vault secret per selected
    user, and update the existing Automation Account variables needed by the
    current runbook. This avoids re-running the interactive Step 1 picker.
.EXAMPLE
    .\tools\Add-StorylineAgents.ps1
.EXAMPLE
    .\tools\Add-StorylineAgents.ps1 -Search Sofia
.EXAMPLE
    .\tools\Add-StorylineAgents.ps1 -AutoFromProfiles -ResetPassword -StoreInKeyVault -UpdateAutomationVariables
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$ProfilesPath = (Join-Path $PSScriptRoot '..\Storyline\profiles.md'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$Search = '',
    [switch]$AutoFromProfiles,
    [switch]$ResetPassword,
    [switch]$NoPasswordReset,
    [switch]$StoreInKeyVault,
    [switch]$UpdateAutomationVariables,
    [string]$AgentPassword,
    [switch]$RevealPassword
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function New-LabPassword {
    -join ((65..90) + (97..122) + (48..57) + (33,35,36,37) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
}

function Get-StorylineProfiles {
    param([string]$Path)
    $profiles = @{}
    if (-not (Test-Path $Path)) { return $profiles }

    $current = $null
    foreach ($line in Get-Content $Path -Encoding utf8) {
        if ($line -match '^##\s+(.+?)\s*$') {
            $current = [ordered]@{ displayName = $Matches[1].Trim() }
            $profiles[$current.displayName.ToLowerInvariant()] = $current
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\-\s+\*\*UPN:\*\*\s+(.+?)\s*$') { $current.upn = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Role:\*\*\s+(.+?)\s*$') { $current.role = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Location:\*\*\s+(.+?)\s*$') { $current.location = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Department:\*\*\s+(.+?)\s*$') { $current.department = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Licenses:\*\*\s+(.+?)\s*$') { $current.licenses = $Matches[1].Trim(); continue }
    }

    return $profiles
}

function Resolve-DefaultDepartment {
    param([string]$Role, [string]$Department)
    if ($Department) { return $Department }
    switch -Regex ($Role) {
        'Project' { 'Project Management'; break }
        'Platform|Engineer' { 'Platform Engineering'; break }
        'HR|People|Talent' { 'HR'; break }
        'Legal|Lawyer|Counsel' { 'Legal'; break }
        'Sales|Account' { 'Sales'; break }
        'Data|Scientist|Analyst' { 'Data Science'; break }
        'Security|Cyber' { 'Cybersecurity'; break }
        default { 'Operations' }
    }
}

function Resolve-DefaultWorkload {
    param([string]$Role)
    switch -Regex ($Role) {
        'Project' { 'Teams'; break }
        'Platform|Engineer' { 'SPO'; break }
        'Data|Scientist' { 'Meetings'; break }
        'Security|Cyber' { 'SPO'; break }
        default { 'SPO' }
    }
}

function Set-AutomationVariable {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AutomationAccountName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    az account set -s $SubscriptionId 2>$null
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Could not acquire Azure management token." }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $jsonValue = $Value | ConvertTo-Json -Compress
    $body = @{ properties = @{ value = $jsonValue; isEncrypted = $true } } | ConvertTo-Json -Depth 4 -Compress
    $uri = "https://management.azure.com/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroup}/providers/Microsoft.Automation/automationAccounts/${AutomationAccountName}/variables/${Name}?api-version=2023-11-01"
    Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' | Out-Null
}

function Sync-InstallationDefinitionsAgents {
    param($Config, [string]$Path)
    if (-not (Test-Path $Path)) { return }

    $defs = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $defs.agents = @($Config.agents)
    $defs.selectedUsers = @($Config.agents | ForEach-Object {
        [ordered]@{
            sam = $_.sam
            userPrincipalName = $_.userPrincipalName
            displayName = $_.displayName
            department = $_.department
            jobTitle = $_.jobTitle
            wave = $_.wave
            workload = $_.workload
            keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $Config.tenant.domain
        }
    })
    if ($defs.steps -and $defs.steps.'1') {
        $defs.steps.'1'.agentCount = @($Config.agents).Count
        $defs.steps.'1'.agents = @($Config.agents)
    }
    $defs | ConvertTo-Json -Depth 30 | Set-Content $Path -Encoding utf8
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
$profiles = Get-StorylineProfiles -Path $ProfilesPath

$definitions = $effective.Definitions

$existingUpns = @{}
foreach ($agent in $config.agents) {
    $upn = Get-AgentUpn -Agent $agent -Domain $config.tenant.domain
    $existingUpns[$upn.ToLowerInvariant()] = $true
}

$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $graphToken) { throw "Azure CLI is not logged in or cannot get a Graph token. Run az login first." }
$headers = @{ Authorization = "Bearer $graphToken" }

$filter = if ($Search) {
    "?`$top=50&`$select=id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled&`$filter=startswith(displayName,'$Search') or startswith(userPrincipalName,'$Search')"
} else {
    "?`$top=999&`$select=id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled"
}
$users = @((Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users$filter" -Headers $headers).value)
$candidates = @()
foreach ($user in $users) {
    if ($user.accountEnabled -eq $false) { continue }
    $upn = [string]$user.userPrincipalName
    if (-not $upn -or $existingUpns.ContainsKey($upn.ToLowerInvariant())) { continue }
    $profile = $null
    if ($profiles.ContainsKey(([string]$user.displayName).ToLowerInvariant())) {
        $profile = $profiles[([string]$user.displayName).ToLowerInvariant()]
    } elseif ($profiles.Values | Where-Object { $_.upn -and $_.upn.ToLowerInvariant() -eq $upn.ToLowerInvariant() }) {
        $profile = ($profiles.Values | Where-Object { $_.upn -and $_.upn.ToLowerInvariant() -eq $upn.ToLowerInvariant() } | Select-Object -First 1)
    }
    if ($AutoFromProfiles -and -not $profile) { continue }

    $role = if ($profile -and $profile.role) { $profile.role } elseif ($user.jobTitle) { $user.jobTitle } else { 'Business User' }
    $department = Resolve-DefaultDepartment -Role $role -Department $(if ($profile -and $profile.department) { $profile.department } elseif ($user.department) { $user.department } else { $null })
    $workload = Resolve-DefaultWorkload -Role $role
    $candidates += [pscustomobject]@{
        DisplayName = $user.displayName
        UPN = $upn
        Sam = ($upn -split '@')[0].ToLowerInvariant()
        Role = $role
        Department = $department
        Workload = $workload
        Copilot = [bool]($profile -and $profile.licenses -match 'Copilot')
        FromProfile = [bool]$profile
    }
}

if (-not $candidates -or $candidates.Count -eq 0) {
    Write-Host "No new candidate users found." -ForegroundColor Yellow
    return
}

Write-Host "New candidate agents:" -ForegroundColor Cyan
for ($i = 0; $i -lt $candidates.Count; $i++) {
    $c = $candidates[$i]
    Write-Host ("  [{0}] {1} <{2}> | {3} | {4} | workload={5} | profile={6}" -f ($i + 1), $c.DisplayName, $c.UPN, $c.Role, $c.Department, $c.Workload, $c.FromProfile)
}

$selectionText = Read-Host "Select users to add (comma-separated numbers, 'all', or blank to cancel)"
if ([string]::IsNullOrWhiteSpace($selectionText)) { Write-Host "Cancelled."; return }

$selected = @()
if ($selectionText.Trim().ToLowerInvariant() -eq 'all') {
    $selected = $candidates
} else {
    foreach ($part in ($selectionText -split ',')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
            $selected += $candidates[$n - 1]
        }
    }
}
if (-not $selected -or $selected.Count -eq 0) { Write-Host "No valid users selected." -ForegroundColor Yellow; return }

if (-not $ResetPassword -and -not $NoPasswordReset) {
    $choice = Read-Host "Reset selected users to a new/shared lab password and store it in Key Vault now? (Y/n)"
    if ($choice -ne 'n') {
        $ResetPassword = $true
        $StoreInKeyVault = $true
        $UpdateAutomationVariables = $true
    }
}
if ($ResetPassword -and -not $AgentPassword) { $AgentPassword = New-LabPassword }

$agentList = @($config.agents)
$nextWave = ((@($config.agents | ForEach-Object { [int]$_.wave }) | Measure-Object -Maximum).Maximum + 1)
$addedAgents = @()
foreach ($c in $selected) {
    if ($existingUpns.ContainsKey($c.UPN.ToLowerInvariant())) { continue }
    $agent = [pscustomobject]@{
        sam = $c.Sam
        userPrincipalName = $c.UPN
        displayName = $c.DisplayName
        department = $c.Department
        jobTitle = $c.Role
        wave = $nextWave
        workload = $c.Workload
        copilotLicense = [bool]$c.Copilot
        workingHours = @{ start = 8; end = 17 }
        filesPerDay = @(3, 6)
        emailsPerDay = @(2, 4)
        style = 'professional, realistic workplace tone, concise and context-aware'
        topics = @('collaboration', 'business operations', 'sensitive data handling', 'project updates')
        existingUser = $true
    }
    $agentList += $agent
    $addedAgents += $agent
}

if (-not $addedAgents -or $addedAgents.Count -eq 0) {
    Write-Host "Selected users were already present; no changes made." -ForegroundColor Yellow
    return
}

$config.agents = $agentList
$config | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding utf8
Sync-InstallationDefinitionsAgents -Config $config -Path $InstallationDefinitionsPath

if ($ResetPassword) {
    Write-Host "Resetting passwords for $($addedAgents.Count) new storyline agent(s)..." -NoNewline
    $resetOk = 0
    foreach ($agent in $addedAgents) {
        $upn = Get-AgentUpn -Agent $agent -Domain $config.tenant.domain
        az ad user update --id $upn --password $AgentPassword --force-change-password-next-sign-in false -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $resetOk++ }
    }
    Write-Host " [OK] $resetOk/$($addedAgents.Count)" -ForegroundColor Green
    if ($RevealPassword) { Write-Host "Expansion password: $AgentPassword" -ForegroundColor Yellow }
}

if ($StoreInKeyVault) {
    $kvName = Get-KeyVaultName -Config $config
    Write-Host "Storing new agent password secrets in Key Vault ($kvName)..." -NoNewline
    foreach ($agent in $addedAgents) {
        $secretName = Get-AgentSecretName -Agent $agent -Domain $config.tenant.domain
        az keyvault secret set --vault-name $kvName --name $secretName --value $AgentPassword -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Failed to store Key Vault secret '$secretName'." }
    }
    Write-Host " [OK]" -ForegroundColor Green
}

if ($UpdateAutomationVariables) {
    $sub = $config.tenant.subscriptionId
    $rg = $config.infrastructure.resourceGroup
    $aaName = $config.infrastructure.automationAccountName
    Write-Host "Updating Automation variables for existing runbook..." -NoNewline
    $configJson = $config | ConvertTo-Json -Depth 50
    Set-AutomationVariable -SubscriptionId $sub -ResourceGroup $rg -AutomationAccountName $aaName -Name 'AgentConfig' -Value $configJson
    foreach ($agent in $addedAgents) {
        $secretName = Get-AgentSecretName -Agent $agent -Domain $config.tenant.domain
        Set-AutomationVariable -SubscriptionId $sub -ResourceGroup $rg -AutomationAccountName $aaName -Name "AgentPwdSecret-$($agent.sam)" -Value $secretName
    }
    Write-Host " [OK]" -ForegroundColor Green
}

Write-Host "Added $($addedAgents.Count) storyline agent(s)." -ForegroundColor Green
Write-Host "Recommended next steps:" -ForegroundColor Cyan
Write-Host "  1. Run Step 2 if the new users need licenses/MFA exclusion group membership."
Write-Host "  2. Run Step 4a if new departments need SharePoint folders or Teams channels."
Write-Host "  3. Run Step 5 only if you want a full runbook redeploy/secret rotation."



