<#
.SYNOPSIS
    Provision SharePoint site + Teams team + department channels for agents.
.DESCRIPTION
    Creates M365 collaboration infrastructure used by the agent runbook:

    1. SHAREPOINT SITE (CorpLab-Documents or existing)
       Document library with department folders from agents.json.
       Agents upload generated PII files to their department folder.
       -> Stores AgentSpoSiteId in Automation variable.

    2. TEAMS TEAM (CorpLab - Departments or existing)
       M365 group-backed team with per-department channels.
       Agents post activity summaries and compliance alerts here.
       -> Stores AgentTeamsGroupId in Automation variable.

    3. TEAM MEMBERSHIP
       All 10 agent users added as members (required for ROPC delegated Teams API).

    4. COLLABORATION TEAMS (optional expansion pack)
       Reads collaborationTeams[] from agents.json and creates dedicated Teams-backed
       SharePoint sites for cross-functional groups such as Security Shadow AI.
       -> Stores AgentCollaborationSites in Automation variable.

    Supports two modes:
      - Create: provisions new site/team from scratch
      - Existing: prompts for existing resource IDs

    All operations are idempotent. Re-running skips already-created resources.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER Mode
    'create' (default) or 'existing'. In 'existing' mode, prompts for IDs.
#>
param(
    $Config,
    [string]$Mode = 'create'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$domain  = $Config.tenant.domain
$rg      = $Config.infrastructure.resourceGroup
$sub     = $Config.tenant.subscriptionId
$aaName  = $Config.infrastructure.automationAccountName
$agents  = $Config.agents
$depts   = @($Config.agents | ForEach-Object { $_.department } | Where-Object { $_ } | Sort-Object -Unique)
if (-not $depts -or $depts.Count -eq 0) { $depts = @('HR', 'Finance', 'Legal', 'Engineering', 'Sales') }

# Resolve actual AA resource group (may differ from config)
$aaRg = $rg
$aaCheck = az automation account show -n $aaName -g $rg --query name -o tsv 2>$null
if (-not $aaCheck) {
    $aaOther = az automation account list --query "[?name=='$aaName'].resourceGroup" -o tsv 2>$null
    if ($aaOther) { $aaRg = $aaOther }
    else {
        Write-Host "  [ERROR] Automation Account '$aaName' not found. Run Step 4 first." -ForegroundColor Red
        return
    }
}

# Graph token. When Azure and Microsoft 365 use separate admin accounts,
# Install-ClaudIA passes the M365 admin token through CLAUDIA_GRAPH_TOKEN.
$gt = if ($env:CLAUDIA_GRAPH_TOKEN) {
    $env:CLAUDIA_GRAPH_TOKEN
} else {
    az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
}
$gh = @{Authorization = "Bearer $gt"; 'Content-Type' = 'application/json'}

# ARM token for AA variables
$mgtToken = az account get-access-token --query accessToken -o tsv 2>$null
$mgtH = @{Authorization = "Bearer $mgtToken"; 'Content-Type' = 'application/json'}
$varBase = "https://management.azure.com/subscriptions/$sub/resourceGroups/$aaRg/providers/Microsoft.Automation/automationAccounts/$aaName/variables"

# ============================================================================
# HELPER: Set AA variable (idempotent PUT)
# ============================================================================
function Set-AAVariable {
    param([string]$Name, [string]$Value, [bool]$Encrypted = $false)
    $body = @{properties = @{value = "`"$Value`""; isEncrypted = $Encrypted}} | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Method PUT -Uri "$varBase/${Name}?api-version=2023-11-01" `
        -Headers $mgtH -Body $body | Out-Null
}

function Resolve-CollabUserId {
    param([string]$Sam)
    $agent = $agents | Where-Object { $_.sam -eq $Sam } | Select-Object -First 1
    $upn = if ($agent) { Get-AgentUpn -Agent $agent -Domain $domain } else { "$Sam@$domain" }
    try {
        (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/${upn}?`$select=id" -Headers $gh).id
    } catch {
        Write-Host "`n    [WARN] User $upn not found -- skip" -ForegroundColor DarkYellow
        $null
    }
}

function Add-CollabTeamMembers {
    param([string]$TeamId, [array]$MemberSams)
    $memberRefs = @()
    foreach ($sam in $MemberSams) {
        $uid = Resolve-CollabUserId -Sam $sam
        if ($uid) { $memberRefs += "https://graph.microsoft.com/v1.0/directoryObjects/$uid" }
    }
    if ($memberRefs.Count -eq 0) { return 0 }

    for ($i = 0; $i -lt $memberRefs.Count; $i += 20) {
        $batch = $memberRefs[$i..[Math]::Min($i + 19, $memberRefs.Count - 1)]
        $body = @{'members@odata.bind' = $batch} | ConvertTo-Json -Depth 3
        try {
            Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groups/$TeamId" `
                -Headers $gh -Body $body | Out-Null
        } catch {
            if ($_.ErrorDetails.Message -notmatch 'already exist') {
                Write-Host "`n    [WARN] Member batch add: $($_.ErrorDetails.Message)" -ForegroundColor DarkYellow
            }
        }
    }
    $memberRefs.Count
}

function Resolve-CollabSharePointSite {
    param([string]$TeamId)
    $siteId = $null
    $retries = 0
    while (-not $siteId -and $retries -lt 6) {
        try {
            $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$TeamId/sites/root?`$select=id" -Headers $gh
            $siteId = $site.id
        } catch {
            $retries++
            if ($retries -lt 6) { Start-Sleep -Seconds 5 }
        }
    }
    $siteId
}

function Resolve-CollabChannels {
    param([string]$TeamId)
    $channelMap = @{}
    $channelRetries = 0
    while ($channelMap.Count -lt 1 -and $channelRetries -lt 10) {
        try {
            $channels = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/teams/$TeamId/channels?`$select=displayName,id" -Headers $gh
            foreach ($ch in $channels.value) {
                $channelMap[$ch.displayName] = $ch.id
            }
        } catch {}
        if ($channelMap.Count -lt 1) {
            $channelRetries++
            Start-Sleep -Seconds 5
        }
    }
    $channelMap
}

function Ensure-CollaborationTeam {
    param($TeamConfig)

    $teamName = "CorpLab - $($TeamConfig.displayName)"
    Write-Host "  Creating Teams team '$teamName'..." -NoNewline

    $safeTeamName = $teamName -replace "'", "''"
    $existingGroups = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$safeTeamName'&`$select=id,resourceProvisioningOptions" -Headers $gh
    $teamsGroups = @($existingGroups.value | Where-Object { $_.resourceProvisioningOptions -contains 'Team' })
    $existingTeam = $teamsGroups | Select-Object -First 1

    if ($existingTeam) {
        $teamId = $existingTeam.id
        Write-Host " [EXISTS] $teamId" -ForegroundColor DarkYellow
    } else {
        $ownerId = Resolve-CollabUserId -Sam $TeamConfig.owner
        if (-not $ownerId) {
            $ownerId = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me?`$select=id" -Headers $gh).id
        }

        $channelDefs = @()
        foreach ($chName in @($TeamConfig.channels)) {
            if ($chName -and $chName -ne 'General') {
                $channelDefs += @{displayName = $chName; description = "$chName workspace"}
            }
        }

        $teamBody = @{
            'template@odata.bind' = "https://graph.microsoft.com/v1.0/teamsTemplates('standard')"
            displayName = $teamName
            description = $TeamConfig.purpose
            channels = $channelDefs
            members = @(
                @{
                    '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                    roles = @('owner')
                    'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$ownerId')"
                }
            )
        } | ConvertTo-Json -Depth 5

        $resp = Invoke-WebRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/teams" `
            -Headers $gh -Body $teamBody -ContentType 'application/json'

        if ($resp.StatusCode -eq 202) {
            $teamId = ($resp.Headers['Content-Location'] -replace ".*teams\('([^']+)'\).*", '$1')
            Write-Host " [OK] $teamId" -ForegroundColor Green
            Start-Sleep -Seconds 15
        } else {
            Write-Host " [FAIL] HTTP $($resp.StatusCode)" -ForegroundColor Red
            return $null
        }
    }

    Write-Host "  Adding collaboration members..." -NoNewline
    $memberCount = Add-CollabTeamMembers -TeamId $teamId -MemberSams @($TeamConfig.members)
    Write-Host " [OK] $memberCount members" -ForegroundColor Green

    Write-Host "  Resolving collaboration SharePoint site..." -NoNewline
    $siteId = Resolve-CollabSharePointSite -TeamId $teamId
    if ($siteId) { Write-Host " [OK] $siteId" -ForegroundColor Green }
    else { Write-Host " [WAIT] Site not ready" -ForegroundColor DarkYellow }

    Write-Host "  Resolving collaboration channels..." -NoNewline
    $channels = Resolve-CollabChannels -TeamId $teamId
    if ($channels.Count -gt 0) { Write-Host " [OK] $($channels.Count) channels" -ForegroundColor Green }
    else { Write-Host " [WARN] Channels not ready yet" -ForegroundColor DarkYellow }

    @{
        Key = $TeamConfig.key
        DisplayName = $TeamConfig.displayName
        TeamName = $teamName
        TeamId = $teamId
        SiteId = $siteId
        Owner = $TeamConfig.owner
        Members = @($TeamConfig.members)
        Channels = $channels
        Purpose = $TeamConfig.purpose
    }
}

# ============================================================================
# MODE: EXISTING — prompt for IDs
# ============================================================================
if ($Mode -eq 'existing') {
    Write-Host "  --- Existing M365 Resources Mode ---" -ForegroundColor White
    Write-Host "    Provide the IDs of your existing resources." -ForegroundColor Gray
    Write-Host ""

    $spoId = Read-Host "    SharePoint site ID (e.g. contoso.sharepoint.com,guid1,guid2)"
    if (-not $spoId) {
        Write-Host "    [ERROR] SharePoint site ID required." -ForegroundColor Red
        return
    }
    Set-AAVariable -Name 'AgentSpoSiteId' -Value $spoId
    Write-Host "    [OK] AgentSpoSiteId stored" -ForegroundColor Green

    $teamId = Read-Host "    Teams group ID (M365 group GUID)"
    if ($teamId) {
        Set-AAVariable -Name 'AgentTeamsGroupId' -Value $teamId
        Write-Host "    [OK] AgentTeamsGroupId stored" -ForegroundColor Green
    } else {
        Write-Host "    [SKIP] Teams integration disabled" -ForegroundColor DarkYellow
    }
    return
}

# ============================================================================
# CREATE: TEAMS TEAM (which also creates a SharePoint site automatically)
# ============================================================================
Write-Host "  Creating Teams team 'CorpLab - Departments'..." -NoNewline

# Check if team already exists
$existingGroups = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq 'CorpLab - Departments'&`$select=id,resourceProvisioningOptions" -Headers $gh
$teamsGroups = @($existingGroups.value | Where-Object { $_.resourceProvisioningOptions -contains 'Team' })
if ($teamsGroups.Count -gt 1) {
    Write-Host "`n  [WARN] $($teamsGroups.Count) teams found with name 'CorpLab - Departments'; using first" -ForegroundColor DarkYellow
}
$existingTeam = $teamsGroups | Select-Object -First 1

if ($existingTeam) {
    $teamId = $existingTeam.id
    Write-Host " [EXISTS] $teamId" -ForegroundColor DarkYellow
} else {
    # Get admin user ID for owner
    $me = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me?`$select=id" -Headers $gh

    $channelDefs = @()
    foreach ($d in $depts) {
        $channelDefs += @{displayName = $d; description = "$d department"}
    }

    $teamBody = @{
        'template@odata.bind' = "https://graph.microsoft.com/v1.0/teamsTemplates('standard')"
        displayName = 'CorpLab - Departments'
        description = 'Agent activity channels per department'
        channels = $channelDefs
        members = @(
            @{
                '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                roles = @('owner')
                'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($me.id)')"
            }
        )
    } | ConvertTo-Json -Depth 4

    $resp = Invoke-WebRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/teams" `
        -Headers $gh -Body $teamBody -ContentType 'application/json'

    if ($resp.StatusCode -eq 202) {
        # Extract team ID from Content-Location header
        $teamId = ($resp.Headers['Content-Location'] -replace ".*teams\('([^']+)'\).*", '$1')
        Write-Host " [OK] $teamId" -ForegroundColor Green
        Write-Host "    Waiting 15s for team provisioning..." -ForegroundColor Gray
        Start-Sleep -Seconds 15
    } else {
        Write-Host " [FAIL] HTTP $($resp.StatusCode)" -ForegroundColor Red
        return
    }
}

# ============================================================================
# ADD AGENT USERS AS TEAM MEMBERS
# ============================================================================
Write-Host "  Adding agents as team members..." -NoNewline

# Use /groups API (avoids TeamMember.ReadWrite.All app permission requirement)
$memberRefs = @()
foreach ($agent in $agents) {
    $upn = Get-AgentUpn -Agent $agent -Domain $domain
    try {
        $uid = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/${upn}?`$select=id" -Headers $gh).id
        $memberRefs += "https://graph.microsoft.com/v1.0/directoryObjects/$uid"
    } catch {
        Write-Host "`n    [WARN] User $upn not found -- skip" -ForegroundColor DarkYellow
    }
}

if ($memberRefs.Count -gt 0) {
    # Add in batches of 20 (Graph limit per PATCH)
    for ($i = 0; $i -lt $memberRefs.Count; $i += 20) {
        $batch = $memberRefs[$i..[Math]::Min($i + 19, $memberRefs.Count - 1)]
        $body = @{'members@odata.bind' = $batch} | ConvertTo-Json -Depth 3
        try {
            Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/groups/$teamId" `
                -Headers $gh -Body $body | Out-Null
        } catch {
            # "One or more added object references already exist" is expected on re-run
            if ($_.ErrorDetails.Message -notmatch 'already exist') {
                Write-Host "`n    [WARN] Member batch add: $($_.ErrorDetails.Message)" -ForegroundColor DarkYellow
            }
        }
    }
}
Write-Host " [OK] $($memberRefs.Count) members" -ForegroundColor Green

# ============================================================================
# RESOLVE SHAREPOINT SITE (created automatically by the M365 group)
# ============================================================================
Write-Host "  Resolving SharePoint site..." -NoNewline

$spoSiteId = $null
$retries = 0
while (-not $spoSiteId -and $retries -lt 5) {
    try {
        $site = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$teamId/sites/root?`$select=id" -Headers $gh
        $spoSiteId = $site.id
    } catch {
        $retries++
        if ($retries -lt 5) { Start-Sleep -Seconds 5 }
    }
}

if ($spoSiteId) {
    Write-Host " [OK] $spoSiteId" -ForegroundColor Green
} else {
    Write-Host " [WAIT] Site not ready -- it may take a few minutes." -ForegroundColor DarkYellow
    Write-Host "    Run this step again or set AgentSpoSiteId manually." -ForegroundColor DarkYellow
}

# ============================================================================
# CREATE DEPARTMENT FOLDERS
# ============================================================================
if ($spoSiteId) {
    Write-Host "  Creating department folders..." -NoNewline
    $created = 0
    foreach ($d in $depts) {
        $folderBody = @{
            name = $d
            folder = @{}
            '@microsoft.graph.conflictBehavior' = 'fail'
        } | ConvertTo-Json
        try {
            Invoke-RestMethod -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root/children" `
                -Headers $gh -Body $folderBody | Out-Null
            $created++
        } catch {
            # Folder already exists (nameAlreadyExists) -- expected on re-run
        }
    }
    # Also create Engineering subfolders for Fabric workload
    foreach ($sub in @('datasets', 'schemas', 'reports', 'dashboards', 'diagrams', 'integrations', 'logs')) {
        $subBody = @{name = $sub; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail'} | ConvertTo-Json
        try {
            Invoke-RestMethod -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/Engineering:/children" `
                -Headers $gh -Body $subBody | Out-Null
        } catch {}
    }
    Write-Host " [OK] $created new folders" -ForegroundColor Green
}

# ============================================================================
# RESOLVE CHANNELS + STORE MAPPING
# ============================================================================
Write-Host "  Resolving team channels..." -NoNewline
$channelMap = @{}
$channelRetries = 0
while ($channelMap.Count -lt 2 -and $channelRetries -lt 10) {
    try {
        $channels = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/teams/$teamId/channels?`$select=displayName,id" -Headers $gh
        foreach ($ch in $channels.value) {
            $channelMap[$ch.displayName] = $ch.id
        }
    } catch {}
    if ($channelMap.Count -lt 2) {
        $channelRetries++
        Start-Sleep -Seconds 5
    }
}
if ($channelMap.Count -gt 0) {
    Write-Host " [OK] $($channelMap.Count) channels" -ForegroundColor Green
} else {
    Write-Host " [WARN] Channels not ready yet. Re-run Step 4a later." -ForegroundColor DarkYellow
}

# ============================================================================
# STORE AA VARIABLES
# ============================================================================
Write-Host "  Storing AA variables..." -NoNewline
Set-AAVariable -Name 'AgentTeamsGroupId' -Value $teamId
if ($spoSiteId) {
    Set-AAVariable -Name 'AgentSpoSiteId' -Value $spoSiteId
}
# Store channel mapping as JSON so the runbook doesn't need Graph access to resolve channels
if ($channelMap.Count -gt 0) {
    $channelJson = ($channelMap | ConvertTo-Json -Compress) -replace '"', '\"'
    $chBody = @{properties = @{value = "`"$channelJson`""; isEncrypted = $false}} | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Method PUT -Uri "$varBase/AgentTeamsChannels?api-version=2023-11-01" `
        -Headers $mgtH -Body $chBody | Out-Null
}
Write-Host " [OK]" -ForegroundColor Green

# ============================================================================
# CREATE OPTIONAL COLLABORATION TEAMS + SITES
# ============================================================================
$collaborationSites = @{}
if ($Config.PSObject.Properties.Name -contains 'collaborationTeams' -and $Config.collaborationTeams) {
    Write-Host ""
    Write-Host "  Provisioning collaboration expansion teams..." -ForegroundColor Cyan
    foreach ($ct in $Config.collaborationTeams) {
        $result = Ensure-CollaborationTeam -TeamConfig $ct
        if ($result -and $result.Key) {
            $collaborationSites[$result.Key] = $result
        }
    }

    if ($collaborationSites.Count -gt 0) {
        Write-Host "  Storing collaboration site map..." -NoNewline
        $collabJson = ($collaborationSites | ConvertTo-Json -Depth 10 -Compress) -replace '"', '\"'
        $collabBody = @{properties = @{value = "`"$collabJson`""; isEncrypted = $false}} | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Method PUT -Uri "$varBase/AgentCollaborationSites?api-version=2023-11-01" `
            -Headers $mgtH -Body $collabBody | Out-Null
        Write-Host " [OK] $($collaborationSites.Count) teams" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "  M365 collaboration provisioned:" -ForegroundColor Green
Write-Host "    Team:     CorpLab - Departments ($teamId)" -ForegroundColor Gray
Write-Host "    Channels: $($depts -join ', ')" -ForegroundColor Gray
Write-Host "    Site:     $spoSiteId" -ForegroundColor Gray
Write-Host "    Members:  $($memberRefs.Count) agents" -ForegroundColor Gray
if ($collaborationSites.Count -gt 0) {
    Write-Host "    Expansion teams: $($collaborationSites.Count)" -ForegroundColor Gray
}
