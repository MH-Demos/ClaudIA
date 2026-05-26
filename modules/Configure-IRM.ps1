<#PSScriptInfo

.VERSION 1.0.0

.GUID 9838cc7b-da78-4705-884a-657f18549efd

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
Deploy Insider Risk Management policies for Purview agent telemetry

.RELEASENOTES
Initial version metadata for Deploy Insider Risk Management policies for Purview agent telemetry.

#>
<#
.SYNOPSIS
    Deploy Insider Risk Management policies for Purview agent telemetry.
.DESCRIPTION
    Creates 2 IRM policies that use DLP alerts as triggers, scoped to agent UPNs.
    Requires M365 E5 and active DLP core policies (Step 6a).

    === POLICIES CREATED ===

    1. IRM-DataLeaks-Lab (LeakOfInformation)
       - Triggers on the category-based Exchange DLP policy created in Step 6a
       - Monitors: file downloads, email to external, USB copy, print, cloud upload

    2. IRM-RiskyAI-Lab (RiskyAIUsage)
       - Monitors AI/Copilot usage patterns for sensitive data
       - Requires manual portal enablement of AI indicators

    === MANUAL PORTAL STEPS (printed after deployment) ===

    - IRM > Settings > Policy indicators > Enable 'Generative AI apps'
    - IRM > Priority User Groups > Create 'ClaudIA Agents' with agent UPNs
    - DSPM for AI > Get started (if not already enabled)

    -> Prerequisite: Configure-CoreDLP.ps1 must have run first (DLP policies must exist).
    -> Prerequisite: Connect-IPPSSession must be active.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER Domain
    Tenant domain.
#>
param($Config, [string]$Domain)
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-Host "  Deploying 2 IRM policies..." -ForegroundColor Cyan

# Verify IPPS connection
try { Get-InsiderRiskPolicy -ErrorAction Stop | Out-Null }
catch {
    Write-Host "  [CONNECT] Security & Compliance PowerShell..." -NoNewline
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue
    Write-Host " [OK]" -ForegroundColor Green
}

# Build agent UPN list for priority user group
$agentUpns = $Config.agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $Domain }
Write-Host "  Agent UPNs for IRM scope: $($agentUpns.Count) users" -ForegroundColor Gray

function Set-LabInsiderRiskPolicyScope {
    param([Parameter(Mandatory)][string]$PolicyName, [string[]]$AgentUpns)

    $setCmd = Get-Command Set-InsiderRiskPolicy -ErrorAction SilentlyContinue
    if (-not $setCmd) {
        Write-Host "    [WARN] Set-InsiderRiskPolicy is not available; set policy users in the portal." -ForegroundColor Yellow
        return
    }

    $params = @{ Identity = $PolicyName }
    if ($setCmd.Parameters.ContainsKey('ExchangeLocation')) {
        $params.ExchangeLocation = 'All'
    } elseif ($setCmd.Parameters.ContainsKey('AddExchangeLocation')) {
        $params.AddExchangeLocation = 'All'
    } elseif ($setCmd.Parameters.ContainsKey('Users')) {
        $params.Users = 'All'
    } elseif ($setCmd.Parameters.ContainsKey('AddUsers')) {
        $params.AddUsers = $AgentUpns
    } else {
        Write-Host "    [WARN] $PolicyName scope not updated; this module version does not expose a known user-scope parameter." -ForegroundColor Yellow
        Write-Host "           In Purview, edit the policy and select Users and groups > Include all users and groups." -ForegroundColor DarkYellow
        return
    }

    try {
        Set-InsiderRiskPolicy @params -ErrorAction Stop | Out-Null
        Write-Host "    [OK] $PolicyName scope set to all users" -ForegroundColor Green
    } catch {
        Write-Host "    [WARN] $PolicyName scope update failed -- $($_.Exception.Message)" -ForegroundColor Yellow
        if ($params.ContainsKey('AddExchangeLocation') -and $AgentUpns.Count -gt 0) {
            try {
                Set-InsiderRiskPolicy -Identity $PolicyName -AddExchangeLocation $AgentUpns -ErrorAction Stop | Out-Null
                Write-Host "    [OK] $PolicyName scope set to agent users" -ForegroundColor Green
                return
            } catch {
                Write-Host "    [WARN] $PolicyName agent scope fallback failed -- $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        Write-Host "           In Purview, edit the policy and select Users and groups > Include all users and groups." -ForegroundColor DarkYellow
    }
}

function Set-LabInsiderRiskPolicyIndicators {
    param([Parameter(Mandatory)][string]$PolicyName)

    $setCmd = Get-Command Set-InsiderRiskPolicy -ErrorAction SilentlyContinue
    if (-not $setCmd) { return }

    $desiredIndicators = @(
        'SpoDownload',
        'SpoDownloadV2',
        'OdbDownload',
        'SpoSyncDownload',
        'OdbSyncDownload',
        'SpoFileLabelDowngraded',
        'SpoFileLabelRemoved',
        'SpoFileDeleted',
        'SpoFileDeletedFromFirstStageRecycleBin',
        'SpoFileSharing',
        'EmailExternal',
        'CopyToPersonalCloud',
        'CumulativeExfiltrationDetector',
        'PeerCumulativeExfiltrationDetector',
        'EpoBrowseToUnallowedDomain',
        'BoxContentDownload',
        'DropboxContentDownload',
        'GoogleDriveContentAccess'
    )

    $params = @{ Identity = $PolicyName }
    foreach ($indicator in $desiredIndicators) {
        if ($setCmd.Parameters.ContainsKey($indicator)) {
            $params[$indicator] = $true
        }
    }

    if ($params.Count -le 1) {
        Write-Host "    [WARN] $PolicyName indicators not updated; this module version does not expose indicator switches." -ForegroundColor Yellow
        Write-Host "           In Purview, edit the policy and select Office, exfiltration, obfuscation, and label downgrade indicators." -ForegroundColor DarkYellow
        return
    }

    try {
        Set-InsiderRiskPolicy @params -ErrorAction Stop | Out-Null
        Write-Host "    [OK] $PolicyName indicators enabled ($($params.Count - 1))" -ForegroundColor Green
    } catch {
        Write-Host "    [WARN] $PolicyName indicator update failed -- $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "           In Purview, edit the policy and choose the indicators for download, exfiltration, delete, obfuscation, and label changes." -ForegroundColor DarkYellow
    }
}

function Get-TenantPolicySuffix {
    param([string]$TenantDomain)

    if ([string]::IsNullOrWhiteSpace($TenantDomain)) { return 'TENANT' }
    return (($TenantDomain -split '\.')[0]).ToUpperInvariant()
}

$coreDlpTriggerPolicy = "EXO Policy - $(Get-TenantPolicySuffix -TenantDomain $Domain)"

# 1/2 IRM-DataLeaks-Lab
$irmName1 = 'IRM-DataLeaks-Lab'
$existing1 = Get-InsiderRiskPolicy -Identity $irmName1 -ErrorAction SilentlyContinue
if ($existing1) {
    Write-Host "    [skip] $irmName1 (exists)" -ForegroundColor DarkGray
} else {
    try {
        New-InsiderRiskPolicy `
            -Name $irmName1 `
            -InsiderRiskScenario 'LeakOfInformation' `
            -Triggers 'DlpAlert' `
            -DlpPolicy $coreDlpTriggerPolicy
        Write-Host "    [OK] $irmName1 (DLP-triggered, LeakOfInformation)" -ForegroundColor Green
    } catch {
        Write-Host "    [WARN] $irmName1 -- $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Create manually: IRM > Policies > New > Data leaks > DLP triggers" -ForegroundColor DarkYellow
    }
}
Set-LabInsiderRiskPolicyScope -PolicyName $irmName1 -AgentUpns $agentUpns
Set-LabInsiderRiskPolicyIndicators -PolicyName $irmName1

# 2/2 IRM-RiskyAI-Lab
$irmName2 = 'IRM-RiskyAI-Lab'
$existing2 = Get-InsiderRiskPolicy -Identity $irmName2 -ErrorAction SilentlyContinue
if ($existing2) {
    Write-Host "    [skip] $irmName2 (exists)" -ForegroundColor DarkGray
} else {
    try {
        New-InsiderRiskPolicy `
            -Name $irmName2 `
            -InsiderRiskScenario 'RiskyAIUsage'
        Write-Host "    [OK] $irmName2 (RiskyAIUsage)" -ForegroundColor Green
    } catch {
        Write-Host "    [WARN] $irmName2 -- $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Create manually: IRM > Policies > New > Risky AI usage" -ForegroundColor DarkYellow
    }
}
Set-LabInsiderRiskPolicyScope -PolicyName $irmName2 -AgentUpns $agentUpns
Set-LabInsiderRiskPolicyIndicators -PolicyName $irmName2

# Enable IRM analytics + DLP sync (tenant-level)
try {
    Set-InsiderRiskSetting -AnalyticsEnabled $true -ErrorAction SilentlyContinue
    Write-Host "    [OK] IRM Analytics enabled" -ForegroundColor Green
} catch {
    Write-Host "    [INFO] IRM Analytics: enable manually in portal" -ForegroundColor DarkYellow
}

Write-Host "  2 IRM policies deployed." -ForegroundColor Green
Write-Host ""
Write-Host "  MANUAL PORTAL STEPS:" -ForegroundColor Yellow
Write-Host "    1. IRM > Settings > Policy indicators > Enable Office, Exfiltration, Obfuscation, Label downgrade/removal, and Generative AI indicators." -ForegroundColor Yellow
Write-Host "    2. IRM > Policies > Edit each lab policy > Users and groups > confirm 'Include all users and groups'." -ForegroundColor Yellow
Write-Host "    3. IRM > Priority User Groups > Create 'ClaudIA Agents':" -ForegroundColor Yellow
foreach ($upn in $agentUpns) {
    Write-Host "       - $upn" -ForegroundColor Gray
}
Write-Host "    4. DSPM for AI > Get started (if not already enabled)" -ForegroundColor Yellow



