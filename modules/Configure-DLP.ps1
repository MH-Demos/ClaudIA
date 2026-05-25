<#
.SYNOPSIS
    Configure DSPM DLP policies and IRM Priority User Group.
.DESCRIPTION
    Creates 3 Data Security Posture Management (DSPM) DLP policies in Purview
    to monitor AI-generated content from the autonomous agents.

    === POLICIES CREATED ===

    1. DSPM-AI-PII-Monitor
       Monitors AI interactions (Copilot, ChatGPT) for French PII patterns.
       Locations: Exchange, SharePoint, OneDrive, Teams, Endpoints.
       Mode: TestWithNotifications (audit only, no blocking).

    2. DSPM-AI-IBAN-Restrict
       Blocks sharing of IBAN data through AI-assisted interactions.
       Higher severity than policy 1.

    3. DSPM-AI-NIR-Alert
       Alerts on NIR (social security) exposure via AI tools.
       Triggers Insider Risk Management signal.

    === IRM INSTRUCTIONS (manual steps, printed to console) ===

    - Enable 'Generative AI apps' policy indicators in IRM Settings
    - Create 'ClaudIA Agents' Priority User Group with agent UPNs
    - Enable DSPM for AI in the Purview portal

    -> Customize: Edit policy names, SIT types, or thresholds below.
    -> Requires: ExchangeOnlineManagement module + Security & Compliance admin.
    -> If Connect-IPPSSession fails, run it manually first then re-run Step 6.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER Domain
    Tenant domain.
#>
param($Config, [string]$Domain)
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-Host "  Checking Security & Compliance PowerShell..." -NoNewline
$ippsReady = $false
try {
    # Test if IPPS is already connected by running a lightweight cmdlet
    Get-DlpCompliancePolicy -ErrorAction Stop | Out-Null
    $ippsReady = $true
    Write-Host " [OK] (existing session)" -ForegroundColor Green
} catch {
    Write-Host " connecting..." -NoNewline
    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
        $ippsReady = $true
    } catch {
        Write-Host " [MANUAL]" -ForegroundColor Yellow
        Write-Host "    Could not connect automatically. Run manually:" -ForegroundColor Yellow
        Write-Host "      Connect-IPPSSession" -ForegroundColor Yellow
        Write-Host "    Then re-run: .\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites" -ForegroundColor Yellow
    }
}
if (-not $ippsReady) { return }

# Resolve SIT GUIDs dynamically based on tenant country (they vary by locale)
$country = if ($Config.tenant.country) { $Config.tenant.country } else { 'FR' }
$allSits = Get-DlpSensitiveInformationType -ErrorAction SilentlyContinue

# Map country → primary ID SIT pattern + bank SIT pattern
$sitMap = @{
    'FR' = @{ primary = 'France Social Security|INSEE';          bank = 'International Banking Account|IBAN' }
    'US' = @{ primary = 'U\.S\. Social Security Number';          bank = 'U\.S\. Bank Account|ABA Routing' }
    'UK' = @{ primary = 'U\.K\. National Insurance|NINO';        bank = 'SWIFT|Sort Code' }
    'DE' = @{ primary = 'Germany Identity Card|Germany Tax Identification|Steuer'; bank = 'International Banking Account|IBAN' }
}
$patterns = if ($sitMap[$country]) { $sitMap[$country] } else { $sitMap['FR'] }

$primarySit = $allSits | Where-Object { $_.Name -match $patterns.primary } | Select-Object -First 1
$bankSit    = $allSits | Where-Object { $_.Name -match $patterns.bank } | Select-Object -First 1

if (-not $primarySit -or -not $bankSit) {
    Write-Host "  [WARN] Could not resolve SIT types for country '$country'. DSPM policies require manual setup." -ForegroundColor Yellow
    Write-Host "    Primary SIT ($($patterns.primary)): $(if ($primarySit) { $primarySit.Name } else { 'NOT FOUND' })" -ForegroundColor DarkYellow
    Write-Host "    Bank SIT ($($patterns.bank)): $(if ($bankSit) { $bankSit.Name } else { 'NOT FOUND' })" -ForegroundColor DarkYellow
    return
}

Write-Host "  SIT resolved ($country): $($primarySit.Name), $($bankSit.Name)" -ForegroundColor Gray

$agentUpns = $Config.agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $Domain }
$sitCondition = @(
    @{name=$primarySit.Name; mincount='1'; maxcount='-1'; confidencelevel='Medium'; classifiertype='Content'}
    @{name=$bankSit.Name; mincount='1'; maxcount='-1'; confidencelevel='High'; classifiertype='Content'}
)

# Policy 1: DSPM CopilotStudio PII Monitor
$pol1Name = 'DLP-CopilotStudio-PII-Monitor'
Write-Host "  Creating $pol1Name..." -NoNewline
try {
    $existingPol1 = Get-DlpCompliancePolicy -Identity $pol1Name -ErrorAction SilentlyContinue
    if ($existingPol1) { Write-Host " [SKIP] (exists)" -ForegroundColor DarkGray }
    else {
        New-DlpCompliancePolicy -Name $pol1Name -Mode 'TestWithNotifications' -ExchangeLocation 'All' -SharePointLocation 'All' -ErrorAction Stop | Out-Null
        # Pass hashtable array directly — NOT JSON string (S&C cmdlet expects [Hashtable[]])
        New-DlpComplianceRule -Name "${pol1Name}-Rule" -Policy $pol1Name `
            -ContentContainsSensitiveInformation $sitCondition -NotifyUser 'SiteAdmin' -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    }
} catch {
    Write-Host " [SKIP] $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# Policy 2: DSPM AI Labels Restrict
$pol2Name = 'DSPM-AI-Labels-Restrict'
Write-Host "  Creating $pol2Name..." -NoNewline
try {
    $existingPol2 = Get-DlpCompliancePolicy -Identity $pol2Name -ErrorAction SilentlyContinue
    if ($existingPol2) { Write-Host " [SKIP] (exists)" -ForegroundColor DarkGray }
    else {
        New-DlpCompliancePolicy -Name $pol2Name -Mode 'TestWithNotifications' -ExchangeLocation 'All' -SharePointLocation 'All' -ErrorAction Stop | Out-Null
        New-DlpComplianceRule -Name "${pol2Name}-Rule" -Policy $pol2Name `
            -ContentContainsSensitiveInformation $sitCondition -BlockAccess $true `
            -BlockAccessScope 'All' -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    }
} catch {
    Write-Host " [SKIP] $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# Policy 3: ClaudIA Activity Audit
$pol3Name = 'DSPM-AI-ClaudIAActivity-Audit'
Write-Host "  Creating $pol3Name..." -NoNewline
try {
    $existingPol3 = Get-DlpCompliancePolicy -Identity $pol3Name -ErrorAction SilentlyContinue
    if ($existingPol3) { Write-Host " [SKIP] (exists)" -ForegroundColor DarkGray }
    else {
        New-DlpCompliancePolicy -Name $pol3Name -Mode 'TestWithNotifications' -ExchangeLocation 'All' -SharePointLocation 'All' -OneDriveLocation 'All' -ErrorAction Stop | Out-Null
        New-DlpComplianceRule -Name "${pol3Name}-Rule" -Policy $pol3Name `
            -ContentContainsSensitiveInformation $sitCondition -ReportSeverityLevel 'Low' -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    }
} catch {
    Write-Host " [SKIP] $($_.Exception.Message)" -ForegroundColor DarkYellow
}

Write-Host "  3 DSPM DLP policies configured." -ForegroundColor Green
Write-Host ""
Write-Host "  MANUAL STEPS (Purview Portal):" -ForegroundColor Yellow
Write-Host "    1. IRM > Settings > Policy indicators > Enable 'Generative AI apps'" -ForegroundColor Yellow
Write-Host "    2. IRM > Settings > Priority user groups > Create 'ClaudIA Agents'" -ForegroundColor Yellow
Write-Host "       Add these UPNs:" -ForegroundColor Yellow
foreach ($upn in $agentUpns) { Write-Host "         $upn" -ForegroundColor Gray }
Write-Host "    3. DSPM for AI > AI security > Get started" -ForegroundColor Yellow
