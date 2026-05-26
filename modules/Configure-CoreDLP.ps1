<#PSScriptInfo

.VERSION 1.0.0

.GUID 0d340b78-0eeb-43e8-8a40-43a03ea5381a

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
Deploy category-based core DLP policies for Purview reporting

.RELEASENOTES
Initial version metadata for Deploy category-based core DLP policies for Purview reporting.

#>
<#
.SYNOPSIS
    Deploy category-based core DLP policies for Purview reporting.
.DESCRIPTION
    Creates one DLP policy per workload and adds rules grouped by sensitive data
    category. Exchange, SharePoint, OneDrive, and Teams get Internal and
    Outbound rules per category. Endpoint and Copilot get one rule per category.

    Policies created:
      - EXO Policy - <tenant>
      - SPO Policy - <tenant>
      - ODB Policy - <tenant>
      - Teams Policy - <tenant>
      - Endpoint Policy - <tenant>
      - Copilot Policy - <tenant>

    Rule prefixes:
      - EXO - <Category> Internal/Outbound
      - SPO - <Category> Internal/Outbound
      - ODB - <Category> Internal/Outbound
      - Teams - <Category> Internal/Outbound
      - EDLP - <Category>
      - Copilot - <Category>

    Sensitivity label correlation is intentionally kept out of the Copilot DLP
    policy. The Purview portal marks sensitivity-label conditions as
    incompatible when editing Copilot-only DLP locations.

    All policies deploy in AUDIT mode (TestWithNotifications) by default.
    Use -EnforceMode to switch supported actions to Enable.

    References:
      - SIT names are resolved dynamically with Get-DlpSensitiveInformationType.
      - Copilot policy location uses the Microsoft documented Applications
        workload location 470f2276-e011-4e9d-a6ec-20768be3a4b0.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER Domain
    Tenant domain.
.PARAMETER EnforceMode
    Switch to Enable mode instead of TestWithNotifications.
#>
param($Config, [string]$Domain, [switch]$EnforceMode)

$ErrorActionPreference = 'Continue'
$mode = if ($EnforceMode) { 'Enable' } else { 'TestWithNotifications' }
$modeLabel = if ($EnforceMode) { 'ENFORCE' } else { 'AUDIT' }
$complianceEmail = "admin@$Domain"

function Get-TenantPolicySuffix {
    param([string]$TenantDomain)

    if ([string]::IsNullOrWhiteSpace($TenantDomain)) { return 'TENANT' }
    return (($TenantDomain -split '\.')[0]).ToUpperInvariant()
}

$tenantSuffix = Get-TenantPolicySuffix -TenantDomain $Domain

Write-Host "  Deploying category-based core DLP policies ($modeLabel) for $tenantSuffix..." -ForegroundColor Cyan

try { Get-DlpCompliancePolicy -ErrorAction Stop | Out-Null }
catch {
    Write-Host "  [CONNECT] Security & Compliance PowerShell..." -NoNewline
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-IPPSSession -WarningAction SilentlyContinue
    Write-Host " [OK]" -ForegroundColor Green
}

$allSits = @(Get-DlpSensitiveInformationType -ErrorAction SilentlyContinue)

function Resolve-SitName {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$Fallback
    )

    foreach ($pattern in $Patterns) {
        $match = $allSits | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
        if ($match) { return $match.Name }
    }

    Write-Host "    [WARN] SIT not resolved, using fallback name: $Fallback" -ForegroundColor DarkYellow
    return $Fallback
}

function New-SitCondition {
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [int]$MinConfidence = 75
    )

    $confidenceLevel = if ($MinConfidence -ge 85) { 'High' } elseif ($MinConfidence -ge 65) { 'Medium' } else { 'Low' }
    $validNames = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    return @($validNames | ForEach-Object {
        @{
            name = $_
            mincount = '1'
            maxcount = '-1'
            confidencelevel = $confidenceLevel
            classifiertype = 'Content'
        }
    })
}

function New-PolicyIfNotExists {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block
    )

    $existing = Get-DlpCompliancePolicy -Identity $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "    [skip] $Name (exists)" -ForegroundColor DarkGray
        return
    }

    try {
        & $Block
        Write-Host "    [OK] $Name" -ForegroundColor Green
    } catch {
        Write-Host "    [FAIL] $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-RuleIfNotExists {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Policy,
        [Parameter(Mandatory)][scriptblock]$Block,
        [switch]$RecreateIfExists
    )

    $existing = Get-DlpComplianceRule -Identity $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($RecreateIfExists) {
            try {
                Remove-DlpComplianceRule -Identity $Name -Confirm:$false -ErrorAction Stop
                Write-Host "      [repair] $Name (recreated for workload-compatible actions)" -ForegroundColor DarkYellow
            } catch {
                Write-Host "      [FAIL] $Name -- could not remove incompatible rule: $($_.Exception.Message)" -ForegroundColor Red
                return
            }
        } else {
            Write-Host "      [skip] $Name (exists)" -ForegroundColor DarkGray
            return
        }
    }

    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        & $Block
        Write-Host "      [OK] $Name" -ForegroundColor Green
    } catch {
        Write-Host "      [FAIL] $Name -- $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Remove-RuleIfExists {
    param([Parameter(Mandatory)][string]$Name)

    $existing = Get-DlpComplianceRule -Identity $Name -ErrorAction SilentlyContinue
    if (-not $existing) { return }

    try {
        Remove-DlpComplianceRule -Identity $Name -Confirm:$false -ErrorAction Stop
        Write-Host "      [remove] $Name (unsupported for this workload)" -ForegroundColor DarkYellow
    } catch {
        Write-Host "      [FAIL] $Name -- could not remove unsupported rule: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$sit = @{
    CreditCard = Resolve-SitName -Patterns @('^Credit card number$') -Fallback 'Credit card number'
    EuDebitCard = Resolve-SitName -Patterns @('^EU debit card number$') -Fallback 'EU debit card number'
    AbaRouting = Resolve-SitName -Patterns @('^ABA routing number$') -Fallback 'ABA routing number'

    UsSsn = Resolve-SitName -Patterns @('U\.S\. social security number') -Fallback 'U.S. social security number (SSN)'
    UsDriversLicense = Resolve-SitName -Patterns @('U\.S\. driver') -Fallback "U.S. driver's license number"
    Passport = Resolve-SitName -Patterns @('U\.S\./U\.K\. passport number', 'passport number') -Fallback 'U.S./U.K. passport number'
    AllPhysicalAddresses = Resolve-SitName -Patterns @('^All Physical Addresses$') -Fallback 'All Physical Addresses'
    AllFullNames = Resolve-SitName -Patterns @('^All full names$') -Fallback 'All full names'

    MedicalTerms = Resolve-SitName -Patterns @('^All medical terms and conditions$') -Fallback 'All medical terms and conditions'
    DeaNumber = Resolve-SitName -Patterns @('Drug Enforcement Agency.*DEA') -Fallback 'Drug Enforcement Agency (DEA) number'
    MedicareMbi = Resolve-SitName -Patterns @('Medicare Beneficiary Identifier') -Fallback 'Medicare Beneficiary Identifier (MBI) card'
    Icd10 = Resolve-SitName -Patterns @('International classification of diseases.*ICD-10') -Fallback 'International classification of diseases (ICD-10-CM)'
    LabTestTerms = Resolve-SitName -Patterns @('^Lab test terms$') -Fallback 'Lab test terms'

    UsBankAccount = Resolve-SitName -Patterns @('U\.S\. bank account number') -Fallback 'U.S. bank account number'
    Iban = Resolve-SitName -Patterns @('International banking account number.*IBAN') -Fallback 'International banking account number (IBAN)'
    Swift = Resolve-SitName -Patterns @('^SWIFT code$') -Fallback 'SWIFT code'
    UsItin = Resolve-SitName -Patterns @('U\.S\. individual taxpayer identification') -Fallback 'U.S. individual taxpayer identification number (ITIN)'

    ClientSecretApiKey = Resolve-SitName -Patterns @('^Client secret / API key$') -Fallback 'Client secret / API key'
    EntraClientSecret = Resolve-SitName -Patterns @('Microsoft Entra client secret') -Fallback 'Microsoft Entra client secret'
    GithubPat = Resolve-SitName -Patterns @('GitHub Personal Access Token') -Fallback 'GitHub Personal Access Token'
    UserLoginCredentials = Resolve-SitName -Patterns @('^User login credentials$') -Fallback 'User login credentials'

    IpAddress = Resolve-SitName -Patterns @('^IP address$') -Fallback 'IP address'
    X509PrivateKey = Resolve-SitName -Patterns @('X\.509 certificate private key') -Fallback 'X.509 certificate private key'
    AzureSqlConnection = Resolve-SitName -Patterns @('Azure SQL connection string') -Fallback 'Azure SQL connection string'
}

$categories = @(
    @{
        Name = 'Payment Card Data'
        Severity = 'High'
        MinConfidence = 85
        SitNames = @($sit.CreditCard, $sit.EuDebitCard, $sit.AbaRouting)
    },
    @{
        Name = 'Identity and Personal Data'
        Severity = 'Medium'
        MinConfidence = 75
        SitNames = @($sit.UsSsn, $sit.UsDriversLicense, $sit.Passport, $sit.AllPhysicalAddresses, $sit.AllFullNames)
    },
    @{
        Name = 'Sensitive Personal and Health Data'
        Severity = 'High'
        MinConfidence = 75
        SitNames = @($sit.MedicalTerms, $sit.DeaNumber, $sit.MedicareMbi, $sit.Icd10, $sit.LabTestTerms)
    },
    @{
        Name = 'Financial and Tax Information'
        Severity = 'High'
        MinConfidence = 75
        SitNames = @($sit.UsBankAccount, $sit.AbaRouting, $sit.Iban, $sit.Swift, $sit.UsItin)
    },
    @{
        Name = 'Credentials and Access Secrets'
        Severity = 'High'
        MinConfidence = 85
        SitNames = @($sit.ClientSecretApiKey, $sit.EntraClientSecret, $sit.GithubPat, $sit.UserLoginCredentials)
    },
    @{
        Name = 'Legal and Corporate Sensitive Information'
        Severity = 'Medium'
        MinConfidence = 75
        SitNames = @($sit.AllFullNames, $sit.AllPhysicalAddresses, $sit.UsItin, $sit.Swift)
    },
    @{
        Name = 'Intellectual Property and Technical Information'
        Severity = 'High'
        MinConfidence = 75
        SitNames = @($sit.IpAddress, $sit.AzureSqlConnection, $sit.X509PrivateKey, $sit.ClientSecretApiKey, $sit.GithubPat)
    }
)

$policyNames = @{
    EXO = "EXO Policy - $tenantSuffix"
    SPO = "SPO Policy - $tenantSuffix"
    ODB = "ODB Policy - $tenantSuffix"
    Teams = "Teams Policy - $tenantSuffix"
    Endpoint = "Endpoint Policy - $tenantSuffix"
    Copilot = "Copilot Policy - $tenantSuffix"
}

New-PolicyIfNotExists $policyNames.EXO {
    New-DlpCompliancePolicy -Name $policyNames.EXO -Comment 'Exchange DLP policy grouped by sensitive data category.' -ExchangeLocation 'All' -Mode $mode | Out-Null
}

New-PolicyIfNotExists $policyNames.SPO {
    New-DlpCompliancePolicy -Name $policyNames.SPO -Comment 'SharePoint DLP policy grouped by sensitive data category.' -SharePointLocation 'All' -Mode $mode | Out-Null
}

New-PolicyIfNotExists $policyNames.ODB {
    New-DlpCompliancePolicy -Name $policyNames.ODB -Comment 'OneDrive DLP policy grouped by sensitive data category.' -OneDriveLocation 'All' -Mode $mode | Out-Null
}

New-PolicyIfNotExists $policyNames.Teams {
    New-DlpCompliancePolicy -Name $policyNames.Teams -Comment 'Teams chat and channel DLP policy grouped by sensitive data category.' -TeamsLocation 'All' -Mode $mode | Out-Null
}

New-PolicyIfNotExists $policyNames.Endpoint {
    New-DlpCompliancePolicy -Name $policyNames.Endpoint -Comment 'Endpoint DLP policy grouped by sensitive data category.' -EndpointDlpLocation 'All' -Mode $mode | Out-Null
}

$copilotLocation = '[{"Workload":"Applications","Location":"470f2276-e011-4e9d-a6ec-20768be3a4b0","Inclusions":[{"Type":"Tenant","Identity":"All"}]}]'
New-PolicyIfNotExists $policyNames.Copilot {
    New-DlpCompliancePolicy -Name $policyNames.Copilot -Comment 'Microsoft 365 Copilot and Copilot Chat DLP policy grouped by sensitive data category.' -Locations $copilotLocation -EnforcementPlanes @('CopilotExperiences') -Mode $mode | Out-Null
}

foreach ($category in $categories) {
    $condition = New-SitCondition -Names $category.SitNames -MinConfidence $category.MinConfidence
    $severity = $category.Severity

    $exoInternal = "EXO - $($category.Name) Internal"
    New-RuleIfNotExists -Name $exoInternal -Policy $policyNames.EXO -Block {
        New-DlpComplianceRule -Name $exoInternal -Policy $policyNames.EXO `
            -ContentContainsSensitiveInformation $condition `
            -FromScope 'InOrganization' -NonBifurcatingAccessScope 'HasInternal' `
            -NotifyUser 'LastModifier' -NotifyPolicyTipDisplayOption 'Dialog' `
            -NotifyPolicyTipCustomText "Sensitive data category detected: $($category.Name) (internal sharing)." `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $exoOutbound = "EXO - $($category.Name) Outbound"
    New-RuleIfNotExists -Name $exoOutbound -Policy $policyNames.EXO -Block {
        New-DlpComplianceRule -Name $exoOutbound -Policy $policyNames.EXO `
            -ContentContainsSensitiveInformation $condition `
            -FromScope 'InOrganization' -NonBifurcatingAccessScope 'HasExternal' `
            -NotifyUser 'LastModifier' -NotifyPolicyTipDisplayOption 'Dialog' -NotifyAllowOverride 'WithJustification' `
            -NotifyPolicyTipCustomText "Sensitive data category detected: $($category.Name) (external sharing)." `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $spoInternal = "SPO - $($category.Name) Internal"
    New-RuleIfNotExists -Name $spoInternal -Policy $policyNames.SPO -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $spoInternal -Policy $policyNames.SPO `
            -ContentContainsSensitiveInformation $condition -AccessScope 'InOrganization' `
            -NotifyUser 'LastModifier','SiteAdmin' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $spoOutbound = "SPO - $($category.Name) Outbound"
    New-RuleIfNotExists -Name $spoOutbound -Policy $policyNames.SPO -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $spoOutbound -Policy $policyNames.SPO `
            -ContentContainsSensitiveInformation $condition -AccessScope 'NotInOrganization' `
            -BlockAccess $true -BlockAccessScope 'PerUser' `
            -NotifyUser 'LastModifier','SiteAdmin' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $odbInternal = "ODB - $($category.Name) Internal"
    New-RuleIfNotExists -Name $odbInternal -Policy $policyNames.ODB -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $odbInternal -Policy $policyNames.ODB `
            -ContentContainsSensitiveInformation $condition -AccessScope 'InOrganization' `
            -NotifyUser 'LastModifier','SiteAdmin' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $odbOutbound = "ODB - $($category.Name) Outbound"
    New-RuleIfNotExists -Name $odbOutbound -Policy $policyNames.ODB -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $odbOutbound -Policy $policyNames.ODB `
            -ContentContainsSensitiveInformation $condition -AccessScope 'NotInOrganization' `
            -BlockAccess $true -BlockAccessScope 'PerUser' `
            -NotifyUser 'LastModifier','SiteAdmin' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $teamsInternal = "Teams - $($category.Name) Internal"
    New-RuleIfNotExists -Name $teamsInternal -Policy $policyNames.Teams -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $teamsInternal -Policy $policyNames.Teams `
            -ContentContainsSensitiveInformation $condition -AccessScope 'InOrganization' `
            -NotifyUser 'LastModifier' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $teamsOutbound = "Teams - $($category.Name) Outbound"
    New-RuleIfNotExists -Name $teamsOutbound -Policy $policyNames.Teams -RecreateIfExists -Block {
        New-DlpComplianceRule -Name $teamsOutbound -Policy $policyNames.Teams `
            -ContentContainsSensitiveInformation $condition -AccessScope 'NotInOrganization' `
            -NotifyUser 'LastModifier' `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $endpointRule = "EDLP - $($category.Name)"
    New-RuleIfNotExists -Name $endpointRule -Policy $policyNames.Endpoint -Block {
        New-DlpComplianceRule -Name $endpointRule -Policy $policyNames.Endpoint `
            -ContentContainsSensitiveInformation $condition `
            -EndpointDlpRestrictions @(
                @{Setting='Print';Value='Audit'},
                @{Setting='CopyPaste';Value='Audit'},
                @{Setting='RemovableMedia';Value='Audit'},
                @{Setting='CloudEgress';Value='Audit'}
            ) `
            -NotifyUser 'LastModifier' `
            -NotifyPolicyTipCustomText "Sensitive data category detected on endpoint: $($category.Name)." `
            -GenerateIncidentReport $complianceEmail -IncidentReportContent 'All' -ReportSeverityLevel $severity | Out-Null
    }

    $copilotRule = "Copilot - $($category.Name)"
    New-RuleIfNotExists -Name $copilotRule -Policy $policyNames.Copilot -Block {
        New-DlpComplianceRule -Name $copilotRule -Policy $policyNames.Copilot `
            -ContentContainsSensitiveInformation $condition `
            -RestrictAccess @(@{setting='ExcludeContentProcessing';value='Block'}) `
            -ReportSeverityLevel $severity | Out-Null
    }
}

foreach ($labelPath in @('Confidential/Conf-HR', 'Confidential/Conf-Finance')) {
    $labelRule = "Copilot - Label - $(($labelPath -replace '/', ' - '))"
    Remove-RuleIfExists -Name $labelRule
}

Write-Host "  Category-based core DLP policies deployed ($modeLabel)." -ForegroundColor Green
Write-Host "  Policies: $($policyNames.Values -join ', ')" -ForegroundColor DarkGray
Write-Host "  Incident reports: $complianceEmail" -ForegroundColor DarkGray



