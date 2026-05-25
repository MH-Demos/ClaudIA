<#
.SYNOPSIS
    Installs the May 27 2026 live demo expansion pack.
.DESCRIPTION
    Creates or reuses the Teams-backed SharePoint site LiveDemoMay272026,
    adds the demo personas, uploads the synthetic seed content, and stores
    optional Automation variables used by Invoke-AgentRunbook.ps1 to make
    Copilot search prompts aware of the live demo site.

    This script is intentionally separate from Step 4a so the core lab
    installer remains generic.
.EXAMPLE
    .\tools\Install-LiveDemoMay272026ExpansionPack.ps1
.EXAMPLE
    .\tools\Install-LiveDemoMay272026ExpansionPack.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string]$DisplayName = 'LiveDemoMay272026',
    [string]$RootFolder = 'Purview-Defender-SeedContent',
    [string]$ContentRoot = (Join-Path $PSScriptRoot '..\content-library\live-demo'),
    [switch]$SkipAutomationVariables
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [object]$Body = $null,
        [string]$ContentType = 'application/json'
    )

    if ($Body -ne $null) {
        if ($Body -is [byte[]]) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:GraphHeaders -Body $Body -ContentType $ContentType
        }
        $json = $Body | ConvertTo-Json -Depth 12
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:GraphHeaders -Body $json -ContentType $ContentType
    }

    Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:GraphHeaders
}

function Get-AgentUpnLocal {
    param([string]$Sam)
    $agent = $script:Config.agents | Where-Object { $_.sam -eq $Sam } | Select-Object -First 1
    if ($agent) { return (Get-AgentUpn -Agent $agent -Domain $script:Domain) }
    "$Sam@$script:Domain"
}

function Resolve-UserId {
    param([string]$Sam)
    $upn = Get-AgentUpnLocal -Sam $Sam
    try {
        (Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/users/${upn}?`$select=id").id
    } catch {
        Write-Host "  [WARN] User $upn not found; skipping membership." -ForegroundColor DarkYellow
        $null
    }
}

function Add-TeamMembers {
    param([string]$TeamId, [array]$MemberSams)

    $memberRefs = @()
    foreach ($sam in @($MemberSams | Where-Object { $_ } | Select-Object -Unique)) {
        $uid = Resolve-UserId -Sam $sam
        if ($uid) { $memberRefs += "https://graph.microsoft.com/v1.0/directoryObjects/$uid" }
    }

    if ($memberRefs.Count -eq 0) { return 0 }

    for ($i = 0; $i -lt $memberRefs.Count; $i += 20) {
        $batch = $memberRefs[$i..[Math]::Min($i + 19, $memberRefs.Count - 1)]
        $body = @{'members@odata.bind' = $batch}
        try {
            Invoke-Graph -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groups/$TeamId" -Body $body | Out-Null
        } catch {
            $message = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            if ($message -notmatch 'already exist') {
                Write-Host "  [WARN] Member batch add failed: $message" -ForegroundColor DarkYellow
            }
        }
    }

    $memberRefs.Count
}

function Resolve-TeamSite {
    param([string]$TeamId)

    $site = $null
    $retries = 0
    while (-not $site -and $retries -lt 8) {
        try {
            $site = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups/$TeamId/sites/root?`$select=id,webUrl"
        } catch {
            $retries++
            if ($retries -lt 8) { Start-Sleep -Seconds 10 }
        }
    }
    $site
}

function New-GroupDriveFolderIfMissing {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [AllowEmptyString()][string]$ParentPath,
        [Parameter(Mandatory)][string]$Name
    )

    $body = @{
        name = $Name
        folder = @{}
        '@microsoft.graph.conflictBehavior' = 'fail'
    }

    $uri = if ([string]::IsNullOrWhiteSpace($ParentPath)) {
        "https://graph.microsoft.com/v1.0/groups/$GroupId/drive/root/children"
    } else {
        $encodedParent = (($ParentPath -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        "https://graph.microsoft.com/v1.0/groups/$GroupId/drive/root:/$encodedParent`:/children"
    }

    try {
        Invoke-Graph -Method POST -Uri $uri -Body $body | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-GroupDriveFolderPath {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$FolderPath
    )

    $current = ''
    foreach ($part in @($FolderPath -split '/' | Where-Object { $_ })) {
        [void](New-GroupDriveFolderIfMissing -GroupId $GroupId -ParentPath $current -Name $part)
        $current = if ($current) { "$current/$part" } else { $part }
    }
}

function Publish-SeedContent {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    if (-not (Test-Path -LiteralPath $ContentRoot)) {
        throw "ContentRoot not found: $ContentRoot"
    }

    Ensure-GroupDriveFolderPath -GroupId $GroupId -FolderPath $TargetRoot

    $files = Get-ChildItem -LiteralPath $ContentRoot -Recurse -File |
        Where-Object { $_.Name -ne 'README.md' } |
        Sort-Object FullName

    $contentRootFull = [System.IO.Path]::GetFullPath($ContentRoot).TrimEnd('\', '/')
    $uploaded = 0
    foreach ($file in $files) {
        $fileFull = [System.IO.Path]::GetFullPath($file.FullName)
        $relative = $fileFull.Substring($contentRootFull.Length).TrimStart('\', '/').Replace('\', '/')
        $targetPath = "$TargetRoot/$relative"
        $targetFolder = (Split-Path $targetPath -Parent).Replace('\', '/')
        Ensure-GroupDriveFolderPath -GroupId $GroupId -FolderPath $targetFolder

        $encodedPath = (($targetPath -split '/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

        if ($WhatIfPreference) {
            Write-Host "  [WHATIF] Upload live demo seed content: $targetPath" -ForegroundColor Yellow
        } else {
            Invoke-Graph -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/drive/root:/$encodedPath`:/content" `
                -Body $bytes -ContentType 'application/octet-stream' | Out-Null
            $uploaded++
            Write-Host "  [OK] $targetPath" -ForegroundColor Green
        }
    }

    $uploaded
}

function Set-AutomationVariable {
    param([string]$Name, [string]$Value, [bool]$Encrypted = $false)
    $jsonValue = $Value | ConvertTo-Json -Compress
    $body = @{ properties = @{ value = $jsonValue; isEncrypted = $Encrypted } } | ConvertTo-Json -Depth 4 -Compress
    Invoke-RestMethod -Method PUT -Uri "$script:VariableBase/${Name}?api-version=2023-11-01" `
        -Headers $script:ArmHeaders -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json' | Out-Null
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$script:Config = $effective.Config
$script:Domain = $script:Config.tenant.domain

$sub = $script:Config.tenant.subscriptionId
$rg = $script:Config.infrastructure.resourceGroup
$aaName = $script:Config.infrastructure.automationAccountName

az account set -s $sub 2>$null
$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $graphToken) { throw "Could not acquire Microsoft Graph token. Run az login first." }
$script:GraphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }

$armToken = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $armToken) { throw "Could not acquire Azure management token. Run az login first." }
$script:ArmHeaders = @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' }

$aaId = az resource list --resource-type Microsoft.Automation/automationAccounts --query "[?name=='$aaName'].id | [0]" -o tsv 2>$null
if ($aaId -and $aaId -match '/resourceGroups/([^/]+)/') { $rg = $Matches[1] }
$script:VariableBase = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/variables"

Write-Host "=== Live demo expansion pack: $DisplayName ===" -ForegroundColor Cyan

$safeDisplayName = $DisplayName -replace "'", "''"
$existingGroups = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$safeDisplayName'&`$select=id,displayName,resourceProvisioningOptions"
$team = @($existingGroups.value | Where-Object { $_.resourceProvisioningOptions -contains 'Team' }) | Select-Object -First 1

if ($team) {
    $teamId = $team.id
    Write-Host "  Team exists: $teamId" -ForegroundColor DarkYellow
} else {
    $me = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/me?`$select=id"
    $teamBody = @{
        'template@odata.bind' = "https://graph.microsoft.com/v1.0/teamsTemplates('standard')"
        displayName = $DisplayName
        description = 'Dedicated expansion pack site for the 2026-05-27 Defender, Purview, Copilot, and Sentinel live demo.'
        channels = @(
            @{ displayName = 'Seed Content'; description = 'Synthetic documents for Copilot and Purview discovery' }
            @{ displayName = 'Investigation'; description = 'Defender, Advanced Hunting, and Sentinel evidence' }
        )
        members = @(
            @{
                '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                roles = @('owner')
                'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($me.id)')"
            }
        )
    } | ConvertTo-Json -Depth 5

    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Teams-backed live demo site')) {
        $resp = Invoke-WebRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/teams" `
            -Headers $GraphHeaders -Body $teamBody -ContentType 'application/json'
        if ($resp.StatusCode -ne 202) { throw "Team creation failed with HTTP $($resp.StatusCode)." }
        $teamId = ($resp.Headers['Content-Location'] -replace ".*teams\('([^']+)'\).*", '$1')
        Write-Host "  Team created: $teamId" -ForegroundColor Green
        Start-Sleep -Seconds 15
    }
}

$members = @(
    'priya.sharma',
    'alexander.meyer',
    'emily.johnson',
    'james.wilson',
    'marcus.olsson',
    'laura.gomez',
    'ana.rodriguez'
)

if ($teamId) {
    Write-Host "  Adding demo members..." -NoNewline
    $memberCount = Add-TeamMembers -TeamId $teamId -MemberSams $members
    Write-Host " [OK] $memberCount members" -ForegroundColor Green

    Write-Host "  Resolving SharePoint site..." -NoNewline
    $site = Resolve-TeamSite -TeamId $teamId
    if (-not $site -or -not $site.id) { throw "SharePoint site for team $teamId is not ready. Wait a few minutes and re-run this script." }
    Write-Host " [OK] $($site.id)" -ForegroundColor Green

    Write-Host "  Uploading seed content to $RootFolder..." -ForegroundColor Cyan
    $uploaded = Publish-SeedContent -GroupId $teamId -TargetRoot $RootFolder

    if (-not $SkipAutomationVariables -and -not $WhatIfPreference) {
        Write-Host "  Storing Automation variables..." -NoNewline
        Set-AutomationVariable -Name 'AgentLiveDemoSiteId' -Value ([string]$site.id)
        Set-AutomationVariable -Name 'AgentLiveDemoSiteUrl' -Value ([string]$site.webUrl)
        Set-AutomationVariable -Name 'AgentLiveDemoRootFolder' -Value $RootFolder
        $siteJson = @{
            DisplayName = $DisplayName
            TeamId = $teamId
            SiteId = $site.id
            SiteUrl = $site.webUrl
            RootFolder = $RootFolder
            SeedFilesUploaded = $uploaded
            Members = $members
        } | ConvertTo-Json -Depth 10 -Compress
        Set-AutomationVariable -Name 'AgentLiveDemoSite' -Value $siteJson
        Write-Host " [OK]" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Expansion pack ready:" -ForegroundColor Green
    Write-Host "  Team:  $DisplayName ($teamId)" -ForegroundColor Gray
    Write-Host "  Site:  $($site.webUrl)" -ForegroundColor Gray
    Write-Host "  Files: $uploaded" -ForegroundColor Gray
    if (-not $SkipAutomationVariables) {
        Write-Host ""
        Write-Host "Recommended next step:" -ForegroundColor Cyan
        Write-Host "  .\tools\Publish-RunbookOnly.ps1" -ForegroundColor Gray
        Write-Host "  This republishes Invoke-AgentRunbook so Copilot prompts can use the AgentLiveDemo* variables." -ForegroundColor Gray
    }
}
