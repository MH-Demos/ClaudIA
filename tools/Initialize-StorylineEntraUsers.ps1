<#PSScriptInfo

.VERSION 1.0.0

.GUID 0b09f957-2cdd-4454-abb0-e751bfc56f9b

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
Create storyline users and license security groups in Microsoft Entra ID

.RELEASENOTES
Initial version metadata for Create storyline users and license security groups in Microsoft Entra ID.

#>
<#
.SYNOPSIS
    Create storyline users and license security groups in Microsoft Entra ID.
.DESCRIPTION
    Reads Storyline/characters_presentations.md, removes non-storyboard people
    (Sebastian, Karla, and Nabil by default), reviews existing Entra users and
    security groups, then creates missing users and the security groups used for
    group-based license assignment.

    By default the script creates:
      - grp-license-m365-e5: all storyline personas
      - grp-license-m365-copilot: personas whose profile/config requires Copilot

    Use -AssignLicensesToGroups only when the tenant is ready for group-based
    licensing and the selected SKU part numbers are correct.
.EXAMPLE
    .\tools\Initialize-StorylineEntraUsers.ps1 -DryRun
.EXAMPLE
    .\tools\Initialize-StorylineEntraUsers.ps1 -AutoApprove -RevealPassword
.EXAMPLE
    .\tools\Initialize-StorylineEntraUsers.ps1 -AssignLicensesToGroups -M365SkuPartNumber SPE_E5 -CopilotSkuPartNumber Microsoft_365_Copilot
#>
param(
    [string]$ProfilesPath = (Join-Path $PSScriptRoot '..\Storyline\characters_presentations.md'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$Domain,
    [string]$UsageLocation = 'US',
    [string]$InitialPassword,
    [switch]$RevealPassword,
    [switch]$ForceChangePasswordNextSignIn,
    [switch]$UpdateExistingUsers,
    [switch]$AssignLicensesToGroups,
    [string]$M365SkuPartNumber,
    [string]$CopilotSkuPartNumber,
    [string[]]$ExcludeNames = @('Sebastian Zamorano', 'Sebastian "Kaz" Zamorano', 'Sebastian “Kaz” Zamorano', 'Karla Penzo', 'Nabil Senoussaoui'),
    [string]$M365LicenseGroupName = 'grp-license-m365-e5',
    [string]$CopilotLicenseGroupName = 'grp-license-m365-copilot',
    [switch]$DryRun,
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'

function New-LabPassword {
    -join ((65..90) + (97..122) + (48..57) + (33,35,36,37) | Get-Random -Count 18 | ForEach-Object { [char]$_ })
}

function ConvertTo-MailNickname {
    param([Parameter(Mandatory)][string]$Value)
    $nickname = ($Value -split '@')[0].ToLowerInvariant()
    $nickname = $nickname -replace '[^a-z0-9._-]', ''
    if ([string]::IsNullOrWhiteSpace($nickname)) { throw "Cannot derive mailNickname from '$Value'." }
    return $nickname
}

function ConvertTo-JsonBody {
    param([Parameter(Mandatory)]$Value, [int]$Depth = 10)
    return [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth $Depth -Compress))
}

function Invoke-GraphGetAll {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $items = @()
    $next = $Uri
    while ($next) {
        $response = Invoke-RestMethod -Method GET -Uri $next -Headers $Headers
        if ($response.value) { $items += @($response.value) }
        $next = $response.'@odata.nextLink'
    }
    return $items
}

function Get-StorylineProfiles {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Profiles file not found: $Path" }

    $profiles = @()
    $current = $null
    foreach ($line in Get-Content $Path -Encoding utf8) {
        if ($line -match '^#\s+(.+?)\s*$') {
            if ($current -and $current.displayName -ne 'ClaudIA - Characters Presentations') {
                $profiles += [pscustomobject]$current
            }
            $current = [ordered]@{
                displayName = $Matches[1].Trim()
                userPrincipalName = ''
                jobTitle = ''
                department = ''
                usageLocation = $UsageLocation
                licenses = ''
            }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\-\s+\*\*UPN:\*\*\s+(.+?)\s*$') { $current.userPrincipalName = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Role:\*\*\s+(.+?)\s*$') { $current.jobTitle = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Department:\*\*\s+(.+?)\s*$') { $current.department = $Matches[1].Trim(); continue }
        if ($line -match '^\-\s+\*\*Licenses:\*\*\s+(.+?)\s*$') { $current.licenses = $Matches[1].Trim(); continue }
    }
    if ($current -and $current.displayName -ne 'ClaudIA - Characters Presentations') {
        $profiles += [pscustomobject]$current
    }

    return @($profiles | Where-Object { $_.userPrincipalName })
}

function Merge-AgentConfigMetadata {
    param(
        [Parameter(Mandatory)]$Profiles,
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return $Profiles }
    $config = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $script:Domain -and $config.tenant.domain) { $script:Domain = [string]$config.tenant.domain }

    $agentsByUpn = @{}
    foreach ($agent in @($config.agents)) {
        if ($agent.userPrincipalName) {
            $agentsByUpn[[string]$agent.userPrincipalName.ToLowerInvariant()] = $agent
        }
    }

    foreach ($profile in $Profiles) {
        $key = [string]$profile.userPrincipalName.ToLowerInvariant()
        if (-not $agentsByUpn.ContainsKey($key)) { continue }
        $agent = $agentsByUpn[$key]
        if ($null -ne $agent.copilotLicense -and [bool]$agent.copilotLicense -and $profile.licenses -notmatch 'Copilot') {
            $profile.licenses = (($profile.licenses, 'Copilot') | Where-Object { $_ }) -join ' + '
        }
    }
    return $Profiles
}

function Get-GraphUserByUpn {
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $escapedUpn = $Upn.Replace("'", "''")
    try {
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$escapedUpn'&`$select=id,displayName,userPrincipalName,mail,jobTitle,department,usageLocation,accountEnabled,assignedLicenses"
        return @((Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers).value | Select-Object -First 1)[0]
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
        throw
    }
}

function Get-GraphSecurityGroupByName {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $escapedName = $DisplayName.Replace("'", "''")
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$escapedName'&`$select=id,displayName,description,mailEnabled,securityEnabled,mailNickname,assignedLicenses"
    return @((Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers).value | Where-Object { $_.securityEnabled -eq $true } | Select-Object -First 1)[0]
}

function Ensure-GraphSecurityGroup {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][hashtable]$Headers,
        [switch]$DryRun
    )

    $group = Get-GraphSecurityGroupByName -DisplayName $DisplayName -Headers $Headers
    if ($group) { return [pscustomobject]@{ Group = $group; Created = $false } }
    if ($DryRun) { return [pscustomobject]@{ Group = [pscustomobject]@{ id = $null; displayName = $DisplayName }; Created = $true } }

    $body = @{
        displayName = $DisplayName
        description = $Description
        mailEnabled = $false
        mailNickname = ConvertTo-MailNickname -Value $DisplayName
        securityEnabled = $true
    }
    $created = Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Headers $Headers -Body (ConvertTo-JsonBody $body)
    return [pscustomobject]@{ Group = $created; Created = $true }
}

function Ensure-UserMemberOfGroup {
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)][hashtable]$Headers,
        [switch]$DryRun
    )

    if ($DryRun -or -not $Group.id -or -not $User.id) { return 'would-add' }

    $memberUri = "https://graph.microsoft.com/v1.0/groups/$($Group.id)/members/$($User.id)/`$ref"
    try {
        Invoke-RestMethod -Method GET -Uri $memberUri -Headers $Headers | Out-Null
        return 'exists'
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw }
    }

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($User.id)" }
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$($Group.id)/members/`$ref" -Headers $Headers -Body (ConvertTo-JsonBody $body) | Out-Null
    return 'added'
}

function Resolve-SubscribedSku {
    param(
        [Parameter(Mandatory)][string]$SkuPartNumber,
        [Parameter(Mandatory)]$SubscribedSkus
    )

    if ([string]::IsNullOrWhiteSpace($SkuPartNumber)) { return $null }
    return @($SubscribedSkus | Where-Object { $_.skuPartNumber -eq $SkuPartNumber } | Select-Object -First 1)[0]
}

function Set-GroupLicense {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)]$Sku,
        [Parameter(Mandatory)][hashtable]$Headers,
        [switch]$DryRun
    )

    if ($DryRun) { return 'would-assign' }
    if (-not $Group.id) { throw "Group id is missing for '$($Group.displayName)'." }
    if (@($Group.assignedLicenses | Where-Object { $_.skuId -eq $Sku.skuId }).Count -gt 0) { return 'exists' }

    $body = @{
        addLicenses = @(@{ skuId = $Sku.skuId })
        removeLicenses = @()
    }
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$($Group.id)/assignLicense" -Headers $Headers -Body (ConvertTo-JsonBody $body) | Out-Null
    return 'assigned'
}

$profiles = Get-StorylineProfiles -Path $ProfilesPath
$profiles = Merge-AgentConfigMetadata -Profiles $profiles -Path $ConfigPath
if (-not $Domain) { $Domain = $script:Domain }
if (-not $Domain) { $Domain = (($profiles | Select-Object -First 1).userPrincipalName -split '@')[1] }

$excluded = @{}
foreach ($name in $ExcludeNames) { $excluded[$name.ToLowerInvariant()] = $true }

$personas = @($profiles | Where-Object {
    -not $excluded.ContainsKey([string]$_.displayName.ToLowerInvariant())
} | Sort-Object displayName)

foreach ($persona in $personas) {
    if ($persona.userPrincipalName -notmatch '@') {
        $persona.userPrincipalName = "$(ConvertTo-MailNickname -Value $persona.displayName)@$Domain"
    }
}

if (-not $personas -or $personas.Count -eq 0) { throw "No storyline personas found after exclusions." }
$generatedInitialPassword = $false
if (-not $InitialPassword) {
    $InitialPassword = New-LabPassword
    $generatedInitialPassword = $true
    $RevealPassword = $true
}

$copilotPersonas = @($personas | Where-Object { $_.licenses -match 'Copilot' })
$licenseGroups = @(
    [pscustomobject]@{
        DisplayName = $M365LicenseGroupName
        Description = 'Storyline personas assigned to Microsoft 365 E5 by group-based licensing.'
        Members = $personas
        SkuPartNumber = $M365SkuPartNumber
    },
    [pscustomobject]@{
        DisplayName = $CopilotLicenseGroupName
        Description = 'Storyline personas assigned to Microsoft 365 Copilot by group-based licensing.'
        Members = $copilotPersonas
        SkuPartNumber = $CopilotSkuPartNumber
    }
)

Write-Host "=== Microsoft Entra storyline bootstrap ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "A continuacion se crearan/validaran los siguientes personajes:" -ForegroundColor Cyan
foreach ($persona in $personas) {
    $copilot = if ($persona.licenses -match 'Copilot') { ' + Copilot' } else { '' }
    Write-Host ("  - {0} <{1}> | {2} | {3} | M365 E5{4}" -f $persona.displayName, $persona.userPrincipalName, $persona.jobTitle, $persona.department, $copilot)
}

Write-Host ""
Write-Host "Personas excluidas por no ser parte del storyboard:" -ForegroundColor DarkYellow
foreach ($name in $ExcludeNames | Select-Object -Unique) {
    Write-Host "  - $name"
}

Write-Host ""
Write-Host "Los siguientes grupos de seguridad se usaran para asignar licencias:" -ForegroundColor Cyan
foreach ($group in $licenseGroups) {
    $skuText = if ($group.SkuPartNumber) { " | SKU: $($group.SkuPartNumber)" } else { '' }
    Write-Host ("  - {0}: {1} miembros{2}" -f $group.DisplayName, @($group.Members).Count, $skuText)
}

Write-Host ""
if (-not $AutoApprove) {
    $choice = Read-Host "Desea continuar? (Y/n)"
    if ($choice -eq 'n') {
        Write-Host "Operacion cancelada."
        return
    }
}

$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $graphToken) { throw "Azure CLI is not logged in or cannot get a Graph token. Run az login first." }
$headers = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }

Write-Host ""
Write-Host "Revisando usuarios en Microsoft Entra..." -ForegroundColor Cyan
$userResults = @()
foreach ($persona in $personas) {
    $existing = Get-GraphUserByUpn -Upn $persona.userPrincipalName -Headers $headers
    $userResults += [pscustomobject]@{
        Persona = $persona
        User = $existing
        Exists = [bool]$existing
    }

    if ($existing) {
        Write-Host ("  [EXISTS] {0} <{1}> | {2} | {3}" -f $existing.displayName, $existing.userPrincipalName, $existing.jobTitle, $existing.department) -ForegroundColor Green
    } else {
        Write-Host ("  [NEW]    {0} <{1}> | {2} | {3}" -f $persona.displayName, $persona.userPrincipalName, $persona.jobTitle, $persona.department) -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "Revisando grupos de seguridad en Microsoft Entra..." -ForegroundColor Cyan
$groupResults = @()
foreach ($groupDef in $licenseGroups) {
    $existingGroup = Get-GraphSecurityGroupByName -DisplayName $groupDef.DisplayName -Headers $headers
    $groupResults += [pscustomobject]@{
        Definition = $groupDef
        Group = $existingGroup
        Exists = [bool]$existingGroup
    }
    if ($existingGroup) {
        Write-Host ("  [EXISTS] {0} ({1})" -f $existingGroup.displayName, $existingGroup.id) -ForegroundColor Green
    } else {
        Write-Host ("  [NEW]    {0}" -f $groupDef.DisplayName) -ForegroundColor DarkYellow
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY-RUN] No changes were written to Microsoft Entra." -ForegroundColor DarkYellow
    return
}

Write-Host ""
Write-Host "Creando o actualizando usuarios..." -ForegroundColor Cyan
$resolvedUsers = @{}
foreach ($result in $userResults) {
    $persona = $result.Persona
    $user = $result.User

    if ($user) {
        if ($UpdateExistingUsers) {
            $patch = @{
                displayName = $persona.displayName
                jobTitle = $persona.jobTitle
                department = $persona.department
                usageLocation = $persona.usageLocation
            }
            Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($user.id)" -Headers $headers -Body (ConvertTo-JsonBody $patch) | Out-Null
            $user = Get-GraphUserByUpn -Upn $persona.userPrincipalName -Headers $headers
            Write-Host ("  [UPDATED] {0}" -f $persona.userPrincipalName) -ForegroundColor Green
        } else {
            Write-Host ("  [SKIP]    {0} already exists" -f $persona.userPrincipalName) -ForegroundColor Gray
        }
    } else {
        $body = @{
            accountEnabled = $true
            displayName = $persona.displayName
            mailNickname = ConvertTo-MailNickname -Value $persona.userPrincipalName
            userPrincipalName = $persona.userPrincipalName
            jobTitle = $persona.jobTitle
            department = $persona.department
            usageLocation = $persona.usageLocation
            passwordProfile = @{
                forceChangePasswordNextSignIn = [bool]$ForceChangePasswordNextSignIn
                password = $InitialPassword
            }
        }
        $user = Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' -Headers $headers -Body (ConvertTo-JsonBody $body)
        Write-Host ("  [CREATED] {0}" -f $persona.userPrincipalName) -ForegroundColor Green
    }

    $resolvedUsers[[string]$persona.userPrincipalName.ToLowerInvariant()] = $user
}

Write-Host ""
Write-Host "Creando grupos y agregando membresias..." -ForegroundColor Cyan
$resolvedGroups = @{}
foreach ($groupDef in $licenseGroups) {
    $ensure = Ensure-GraphSecurityGroup -DisplayName $groupDef.DisplayName -Description $groupDef.Description -Headers $headers
    $group = $ensure.Group
    $resolvedGroups[$groupDef.DisplayName] = $group
    $verb = if ($ensure.Created) { 'CREATED' } else { 'EXISTS' }
    Write-Host ("  [{0}] {1}" -f $verb, $group.displayName) -ForegroundColor Green

    foreach ($member in @($groupDef.Members)) {
        $user = $resolvedUsers[[string]$member.userPrincipalName.ToLowerInvariant()]
        $membership = Ensure-UserMemberOfGroup -User $user -Group $group -Headers $headers
        Write-Host ("    [{0}] {1}" -f $membership.ToUpperInvariant(), $member.userPrincipalName) -ForegroundColor Gray
    }
}

if ($AssignLicensesToGroups) {
    Write-Host ""
    Write-Host "Asignando licencias a grupos..." -ForegroundColor Cyan
    $subscribedSkus = Invoke-GraphGetAll -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Headers $headers

    foreach ($groupDef in $licenseGroups) {
        if (-not $groupDef.SkuPartNumber) {
            Write-Host ("  [SKIP] {0}: no SKU part number provided" -f $groupDef.DisplayName) -ForegroundColor DarkYellow
            continue
        }
        $sku = Resolve-SubscribedSku -SkuPartNumber $groupDef.SkuPartNumber -SubscribedSkus $subscribedSkus
        if (-not $sku) { throw "SKU '$($groupDef.SkuPartNumber)' was not found in subscribedSkus." }
        $group = Get-GraphSecurityGroupByName -DisplayName $groupDef.DisplayName -Headers $headers
        $status = Set-GroupLicense -Group $group -Sku $sku -Headers $headers
        Write-Host ("  [{0}] {1} -> {2}" -f $status.ToUpperInvariant(), $groupDef.DisplayName, $groupDef.SkuPartNumber) -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "Licencias no asignadas automaticamente. Use Entra admin center > Billing > Licenses > Groups, o rerun con -AssignLicensesToGroups y los SKU correctos." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Provisionamiento Entra completado." -ForegroundColor Green
if ($RevealPassword) {
    Write-Host "Password inicial compartido: $InitialPassword" -ForegroundColor Yellow
} elseif ($generatedInitialPassword) {
    Write-Host "Password inicial generado pero no revelado. Recomendado: use -InitialPassword o -RevealPassword en ejecuciones reales." -ForegroundColor Yellow
} else {
    Write-Host "Password inicial definido por parametro -InitialPassword." -ForegroundColor Yellow
}



