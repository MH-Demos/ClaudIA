<#PSScriptInfo

.VERSION 1.0.0

.GUID 46dd4ec3-8689-457f-813e-3c30a5f55ada

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
Provision sensitivity labels required by agent content classification

.RELEASENOTES
Initial version metadata for Provision sensitivity labels required by agent content classification.

#>
<#
.SYNOPSIS
    Provision sensitivity labels required by agent content classification.
.DESCRIPTION
    Creates and publishes sensitivity labels used by the agent runbook to classify
    uploaded files by department. Uses Security & Compliance PowerShell.

    === LABELS CREATED ===

    1. General/All Employees        - No protection, visual marking only
    2. Confidential/All Employees   - Header/footer marking, default for most depts
    3. Conf-HR                      - Sub-label, scoped to HR high-sensitivity files
    4. Conf-Finance                 - Sub-label, scoped to Finance high-sensitivity files
    5. Highly Confidential/AE       - Encryption (Rights Management), Legal high-sensitivity

    === LABEL POLICY ===
    Published to all users (no scoping). Labels appear in Office apps + SharePoint.

    NOTE: Labels take 24-48h to propagate to all M365 services after publication.
    The runbook applies labels via Graph API which works within minutes.

    All operations are idempotent. Existing labels are skipped.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER SkipPublish
    Create labels but don't publish them (useful if you have an existing policy).
#>
param(
    $Config,
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONNECT to Security & Compliance PowerShell
# ============================================================================
Write-Host "  Connecting to Security & Compliance PowerShell..." -NoNewline

# Check if already connected
$connected = $false
try {
    Get-Label -ErrorAction Stop | Out-Null
    $connected = $true
    Write-Host " [OK] (already connected)" -ForegroundColor Green
} catch {
    Write-Host "" # newline
    Write-Host "    Security & Compliance PowerShell is not connected." -ForegroundColor Yellow
    Write-Host "    Run this command first, then re-run this step:" -ForegroundColor Yellow
    Write-Host "      Connect-IPPSSession" -ForegroundColor Cyan
    Write-Host "    (requires ExchangeOnlineManagement module)" -ForegroundColor Gray
    Write-Host ""
    $tryConnect = Read-Host "    Try auto-connect now? (y/N)"
    if ($tryConnect -eq 'y') {
        try {
            Connect-IPPSSession -ShowBanner:$false -ErrorAction Stop
            $connected = $true
            Write-Host "    [OK] Connected" -ForegroundColor Green
        } catch {
            Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "    Connect manually and re-run: .\Install-ClaudIA.ps1 -Step 4" -ForegroundColor Yellow
            return
        }
    } else {
        Write-Host "    [SKIP] Connect manually and re-run Step 4b." -ForegroundColor DarkYellow
        return
    }
}

# ============================================================================
# GET EXISTING LABELS
# ============================================================================
Write-Host "  Checking existing labels..." -NoNewline
$existingLabels = Get-Label -ErrorAction SilentlyContinue
$existingNames = @($existingLabels | ForEach-Object { $_.DisplayName })
Write-Host " found $($existingNames.Count) labels" -ForegroundColor Gray

function Get-AAFirstLabel {
    param(
        [array]$Labels,
        [Parameter(Mandatory)][string]$DisplayName
    )

    @($Labels | Where-Object { $_.DisplayName -eq $DisplayName } | Select-Object -First 1)[0]
}

function Get-AAFirstLabelGuid {
    param($Label)

    if (-not $Label) { return $null }
    $guidValue = $Label.Guid
    if ($guidValue -is [System.Collections.IEnumerable] -and -not ($guidValue -is [string])) {
        $guidValue = @($guidValue | Select-Object -First 1)[0]
    }
    if ($guidValue) { return [string]$guidValue }
    return $null
}

# ============================================================================
# LABEL DEFINITIONS
# ============================================================================
# Order matters: parent labels must be created before sub-labels.
$labelDefs = @(
    @{
        Name        = 'General'
        DisplayName = 'General'
        Tooltip     = 'Non-sensitive business data for general use'
        Comment     = 'Lab label - General classification'
        ContentType = 'File, Email'
        Settings    = @{
            headerEnabled   = 'true'
            headerText      = 'General'
            headerFontSize  = '10'
            headerFontColor = '#999999'
            headerAlignment = 'Right'
        }
    }
    @{
        Name        = 'Confidential'
        DisplayName = 'Confidential'
        Tooltip     = 'Sensitive business data - internal only'
        Comment     = 'Lab label - Confidential classification'
        ContentType = 'File, Email'
        Settings    = @{
            headerEnabled   = 'true'
            headerText      = 'CONFIDENTIAL'
            headerFontSize  = '10'
            headerFontColor = '#FF6600'
            headerAlignment = 'Right'
            footerEnabled   = 'true'
            footerText      = 'This document contains confidential information.'
            footerFontSize  = '8'
            footerFontColor = '#999999'
            footerAlignment = 'Center'
        }
    }
    @{
        Name        = 'Conf-HR'
        DisplayName = 'Conf-HR'
        ParentName  = 'Confidential'
        Tooltip     = 'HR-restricted data (payroll, evaluations, personal records)'
        Comment     = 'Lab sub-label - HR department high-sensitivity'
        ContentType = 'File, Email'
        Settings    = @{
            headerEnabled   = 'true'
            headerText      = 'CONFIDENTIAL - HR'
            headerFontSize  = '10'
            headerFontColor = '#CC0000'
            headerAlignment = 'Right'
            footerEnabled   = 'true'
            footerText      = 'HR restricted - Do not distribute outside HR department.'
            footerFontSize  = '8'
            footerFontColor = '#CC0000'
            footerAlignment = 'Center'
        }
    }
    @{
        Name        = 'Conf-Finance'
        DisplayName = 'Conf-Finance'
        ParentName  = 'Confidential'
        Tooltip     = 'Finance-restricted data (transfers, DSN, invoices)'
        Comment     = 'Lab sub-label - Finance department high-sensitivity'
        ContentType = 'File, Email'
        Settings    = @{
            headerEnabled   = 'true'
            headerText      = 'CONFIDENTIAL - FINANCE'
            headerFontSize  = '10'
            headerFontColor = '#0066CC'
            headerAlignment = 'Right'
            footerEnabled   = 'true'
            footerText      = 'Finance restricted - Authorized personnel only.'
            footerFontSize  = '8'
            footerFontColor = '#0066CC'
            footerAlignment = 'Center'
        }
    }
    @{
        Name        = 'HighlyConfidential'
        DisplayName = 'Highly Confidential'
        Tooltip     = 'Highly sensitive data requiring encryption'
        Comment     = 'Lab label - Highly Confidential with RMS encryption'
        ContentType = 'File, Email'
        Settings    = @{
            headerEnabled   = 'true'
            headerText      = 'HIGHLY CONFIDENTIAL'
            headerFontSize  = '12'
            headerFontColor = '#CC0000'
            headerAlignment = 'Center'
            footerEnabled   = 'true'
            footerText      = 'HIGHLY CONFIDENTIAL - Unauthorized disclosure is prohibited.'
            footerFontSize  = '8'
            footerFontColor = '#CC0000'
            footerAlignment = 'Center'
        }
    }
)

# ============================================================================
# CREATE LABELS
# ============================================================================
$created = 0
$skipped = 0

foreach ($def in $labelDefs) {
    $displayName = $def.DisplayName
    Write-Host "  Label '$displayName'..." -NoNewline

    # Check if exists (match by DisplayName)
    $exists = Get-AAFirstLabel -Labels @($existingLabels) -DisplayName $displayName
    if ($exists) {
        Write-Host " [EXISTS]" -ForegroundColor DarkYellow
        $skipped++
        continue
    }

    # Build New-Label parameters
    $labelParams = @{
        Name        = $def.Name
        DisplayName = $def.DisplayName
        Tooltip     = $def.Tooltip
        Comment     = $def.Comment
        ContentType = $def.ContentType
    }

    # Sub-label: set ParentId
    if ($def.ParentName) {
        $parent = Get-AAFirstLabel -Labels @($existingLabels) -DisplayName $def.ParentName
        if (-not $parent) {
            # Parent was just created in this run -- retry with delay
            for ($retryP = 0; $retryP -lt 5; $retryP++) {
                Start-Sleep -Seconds 3
                $parent = Get-AAFirstLabel -Labels @(Get-Label -ErrorAction SilentlyContinue) -DisplayName $def.ParentName
                if ($parent) { break }
            }
        }
        if ($parent) {
            $parentGuid = Get-AAFirstLabelGuid -Label $parent
            if (-not $parentGuid) {
                Write-Host " [SKIP] Parent '$($def.ParentName)' has no usable GUID" -ForegroundColor Red
                continue
            }
            $labelParams['ParentId'] = $parentGuid
        } else {
            Write-Host " [SKIP] Parent '$($def.ParentName)' not found after retries" -ForegroundColor Red
            continue
        }
    }

    # Apply visual marking settings
    if ($def.Settings) {
        $labelParams['ApplyContentMarkingHeaderEnabled']   = ($def.Settings.headerEnabled -eq 'true')
        $labelParams['ApplyContentMarkingHeaderText']      = $def.Settings.headerText
        $labelParams['ApplyContentMarkingHeaderFontSize']  = [int]$def.Settings.headerFontSize
        $labelParams['ApplyContentMarkingHeaderFontColor'] = $def.Settings.headerFontColor
        $labelParams['ApplyContentMarkingHeaderAlignment'] = $def.Settings.headerAlignment

        if ($def.Settings.footerEnabled -eq 'true') {
            $labelParams['ApplyContentMarkingFooterEnabled']   = $true
            $labelParams['ApplyContentMarkingFooterText']      = $def.Settings.footerText
            $labelParams['ApplyContentMarkingFooterFontSize']  = [int]$def.Settings.footerFontSize
            $labelParams['ApplyContentMarkingFooterFontColor'] = $def.Settings.footerFontColor
            $labelParams['ApplyContentMarkingFooterAlignment'] = $def.Settings.footerAlignment
        }
    }

    try {
        New-Label @labelParams -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
        $created++
        # Refresh label list for sub-label parent resolution
        $existingLabels = Get-Label -ErrorAction SilentlyContinue
    } catch {
        Write-Host " [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "  Labels: $created created, $skipped already existed" -ForegroundColor Cyan

function Get-LabelPropertyValue {
    param(
        $Label,
        [string]$PropertyName
    )

    $property = $Label.PSObject.Properties[$PropertyName]
    if ($property) { return $property.Value }
    return $null
}

function Test-IsTruthyLabelProperty {
    param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ($Value.ToString() -eq 'True')
}

function Test-IsLabelGroup {
    param($Label)

    foreach ($propertyName in @('IsLabelGroup', 'IsGroup', 'IsParent', 'HasChildren')) {
        if (Test-IsTruthyLabelProperty (Get-LabelPropertyValue -Label $Label -PropertyName $propertyName)) {
            return $true
        }
    }

    foreach ($propertyName in @('LabelType', 'Type', 'ObjectType', 'RecipientTypeDetails')) {
        $value = Get-LabelPropertyValue -Label $Label -PropertyName $propertyName
        if ($value -and $value.ToString() -match 'LabelGroup|Group') {
            return $true
        }
    }

    return $false
}

function Get-PublishableLabelGuids {
    param(
        [array]$Labels,
        [string[]]$Identifiers
    )

    $parentIds = @(
        $Labels | ForEach-Object {
            $parentId = Get-LabelPropertyValue -Label $_ -PropertyName 'ParentId'
            if ($parentId) { $parentId.ToString() }
        }
    )

    $labelGuids = New-Object System.Collections.Generic.List[string]

    foreach ($identifier in $Identifiers) {
        $matches = @(
            $Labels | Where-Object {
                $_.DisplayName -eq $identifier -or
                (Get-LabelPropertyValue -Label $_ -PropertyName 'Name') -eq $identifier -or
                (Get-LabelPropertyValue -Label $_ -PropertyName 'Identity') -eq $identifier
            }
        )
        if ($matches.Count -eq 0) {
            Write-Host "    [WARN] Label '$identifier' was not found for publishing" -ForegroundColor DarkYellow
            continue
        }

        $publishable = @(
            $matches | Where-Object {
                $guid = $_.Guid.ToString()
                (-not (Test-IsLabelGroup -Label $_)) -and ($parentIds -notcontains $guid)
            }
        )

        if ($publishable.Count -eq 0) {
            Write-Host "    [SKIP] Label '$identifier' is a label group/parent and cannot be published directly" -ForegroundColor DarkYellow
            continue
        }

        foreach ($label in $publishable) {
            $guid = $label.Guid.ToString()
            if (-not $labelGuids.Contains($guid)) {
                $labelGuids.Add($guid)
            }
        }
    }

    return @($labelGuids)
}

# ============================================================================
# PUBLISH LABEL POLICY
# ============================================================================
if (-not $SkipPublish) {
    $policyName = 'CorpLab-Labels-Policy'
    Write-Host "  Publishing label policy '$policyName'..."

    $existingPolicy = Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue
    if ($existingPolicy) {
        Write-Host "    [EXISTS]" -ForegroundColor DarkYellow
    } else {
        # Get only publishable lab label GUIDs. Parent labels/label groups are
        # containers in newer Purview tenants and New-LabelPolicy rejects them.
        $targetLabelNames = @(
            'General',
            'General/All Employees',
            'Confidential',
            'Confidential/All Employees',
            'Conf-HR',
            'Conf-Finance',
            'Highly Confidential',
            'Highly Confidential/All Employees'
        )
        $allLabels = @(Get-Label -ErrorAction Stop)
        $labelGuids = Get-PublishableLabelGuids -Labels $allLabels -Identifiers $targetLabelNames

        if ($labelGuids.Count -gt 0) {
            try {
                New-LabelPolicy -Name $policyName `
                    -Labels $labelGuids `
                    -ExchangeLocation 'All' `
                    -Comment 'Lab label policy for autonomous agents' `
                    -ErrorAction Stop | Out-Null
                Write-Host "    [OK] Policy created ($($labelGuids.Count) labels)" -ForegroundColor Green
            } catch {
                Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "    [SKIP] No labels to publish" -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
Write-Host "  NOTE: Labels take 24-48h to propagate to Office apps." -ForegroundColor Yellow
Write-Host "  The runbook applies labels via Graph API (works within minutes)." -ForegroundColor Yellow



