<#PSScriptInfo

.VERSION 1.0.0

.GUID 0ca67639-d16b-45c3-bd8f-50c63358043d

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
Azure Automation Runbook - Parameterized AI-powered autonomous corporate agents

.RELEASENOTES
Initial version metadata for Azure Automation Runbook - Parameterized AI-powered autonomous corporate agents.

#>
<#
.SYNOPSIS
    Azure Automation Runbook - Parameterized AI-powered autonomous corporate agents.
.DESCRIPTION
    Reads agent configuration from Automation variables (AgentConfig JSON).
    Each agent authenticates as themselves (ROPC), uses Azure OpenAI to generate
    unique department-specific content with SIT-precision PII patterns.
    All actions appear under the real agent's identity in M365 audit logs.
.NOTES
    Runtime: PowerShell 7.2 (Azure Automation)
    Config:  AgentConfig (JSON Automation variable) + AgentSitReference (text)
    Auth:    Managed Identity -> OpenAI RBAC, Automation variables -> agent passwords
             ROPC per agent -> Graph API (files, mail, Teams, Copilot)
    Package: ClaudIA (on-the-shelf deployment)

    === SCRIPT LAYOUT (for customization) ===

    SECTION 1: LOAD CONFIGURATION (line ~30)
      Reads AgentConfig JSON, SIT reference, and SPO/Teams IDs from Automation variables.
      -> Customize: Change variable names if you renamed them in Deploy-Runbook.ps1.

    SECTION 2: LABEL + DLP RULES (line ~56)
      Maps file types to sensitivity labels per department. Maps DLP policy names per department.
      -> Customize: Edit $labelRules to change which file types get which label.
                    Edit $dlpPolicies to reference your own DLP policy names.

    SECTION 3: SIT PRECISION REFERENCE (line ~96)
      Text block injected into ALL AI prompts to enforce exact Purview SIT patterns.
      -> Customize: Edit to match your country's PII patterns.
                    Add new patterns here and they will appear in all generated content.

    SECTION 4: BUILD AGENTS FROM CONFIG (line ~147)
      Reads agents from AgentConfig JSON and builds runtime agent objects with prompts.
      -> Customize: Change the prompt template to alter agent behavior.
                    Modify PII requirements per department.

    SECTION 5: EMAIL SCENARIOS (line ~179)
      18 predefined cross-department email scenarios (From/To/Context).
      -> Customize: Add or remove scenarios. From/To use agent SAM names from config.
                    Context describes what the AI should write (with PII instructions).

    SECTION 6: MULTI-TURN THREADS (line ~203)
      Loaded from AgentEmailThreads Automation variable (config/email-threads.json).
      -> Customize: Edit config/email-threads.json to add/modify conversation threads.
                    Each thread has 3-4 messages with reply/forward chains.

    SECTION 7: COPILOT PROMPTS (line ~228)
      Built dynamically from agent config. Only Wave 2 agents with copilotLicense=true.
      -> Customize: Edit $deptSearchTopics and $deptPiiHint to change Copilot query themes.

    SECTION 8: FILE TYPE TEMPLATES (line ~264)
      Document types per department: file type name, extension, AI prompt.
      -> Customize: Add new file types, change extensions (csv/txt/json/md/html/svg),
                    or modify prompts. Each prompt tells OpenAI what content to generate.
                    Emma Leroy (Engineering) has 14 types including multi-format.

    SECTION 9: AUTHENTICATION (line ~319)
      Get-ROPCToken function: acquires delegated token per agent via ROPC.
      -> Customize: Change scopes if you need additional Graph permissions.
                    Uses explicit scopes (not .default) to show real identity in audit logs.

    SECTION 10: AZURE DATA EXPLORER TELEMETRY (line ~352)
      Push-AgentActivity function: sends telemetry to ADX.
      -> Customize: Add fields to the Event dynamic payload.

    SECTION 11: AZURE OPENAI (line ~425)
      Invoke-OAI function: calls GPT-4o-mini via Managed Identity.
      -> Customize: Change temperature, max_tokens, or model parameters.
                    Adjust token limits per file type in the main loop.

    SECTION 12: PURVIEW INTEGRATION (line ~461)
      Label resolution, label application, Teams posting, unlabeled file scanning.
      -> Customize: Modify Resolve-LabelForFile to change label assignment logic.

    SECTION 13: ACTIVITY SCHEDULER (line ~571)
      Randomizes file/email creation times within working hours.
      -> Customize: Adjust delay ranges for more/less realistic timing.

    SECTION 14: MAIN LOOP (line ~605)
      Orchestrates all agents: auth -> schedule -> file creation -> emails -> Teams.
      -> Customize: Add new workload types in the activity dispatch switch.

    SECTION 15: MULTI-TURN THREADS EXECUTION (line ~969)
      Executes 1-2 random conversation threads per run.
      -> Customize: Change thread count per run, add new thread scenarios.
#>

param(
    [string]$RunAsAgent       = '',
    [string]$SendEmails       = 'True',
    [string]$SkipWeekendCheck = 'False',
    [string]$ActivityMode     = 'full',   # full | morning | afternoon | burst
    [string]$ServiceFilter    = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$bSendEmails       = $SendEmails -eq 'True'
$bSkipWeekendCheck = $SkipWeekendCheck -eq 'True'
$requestedServices = @()
if (-not [string]::IsNullOrWhiteSpace($ServiceFilter)) {
    $requestedServices = @($ServiceFilter -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
}

function Test-ServiceRequested {
    param([Parameter(Mandatory)][array]$Aliases)
    if ($requestedServices.Count -eq 0) { return $true }
    foreach ($alias in $Aliases) {
        if ($requestedServices -contains ([string]$alias).ToLowerInvariant()) { return $true }
    }
    return $false
}

# =============================================================================
# LOAD CONFIGURATION from Automation Variables
# =============================================================================
# AgentConfig: JSON string with tenant, infrastructure, agents, schedules
# AgentSitReference: SIT precision patterns text block
# OaiEndpoint, OaiDeployment: OpenAI connection details
# AgentTenantId, AgentAppId: ROPC auth metadata
# AgentKeyVaultName + per-agent secret names: credentials are stored in Key Vault

$configJson = Get-AutomationVariable -Name 'AgentConfig' -ErrorAction Stop
$agentConfig = $configJson | ConvertFrom-Json

$domain         = $agentConfig.tenant.domain
$subscriptionId = $agentConfig.tenant.subscriptionId
$OaiEndpoint    = "https://$($agentConfig.infrastructure.openAiAccountName).openai.azure.com/"
$OaiDeployment  = $agentConfig.infrastructure.openAiModel
$adxConfig      = $agentConfig.adx

function Get-AgentUpn {
    param($AgentConfigItem, [string]$Domain)
    # Keep behavior aligned with modules/Common.ps1 Get-AgentUpn: ignore
    # placeholder domains so secret names match what Step 5 stored in Key Vault.
    if ($AgentConfigItem.userPrincipalName) {
        $configuredUpn = [string]$AgentConfigItem.userPrincipalName
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ($AgentConfigItem.upn) {
        $configuredUpn = [string]$AgentConfigItem.upn
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ("$($AgentConfigItem.sam)" -match '@') { return [string]$AgentConfigItem.sam }
    return "$($AgentConfigItem.sam)@$Domain"
}

function Get-AgentSecretName {
    param($AgentConfigItem, [string]$Domain)
    $upn = Get-AgentUpn -AgentConfigItem $AgentConfigItem -Domain $Domain
    $local = ($upn -split '@')[0].ToLowerInvariant()
    $name = $local -replace '[^a-z0-9-]', '-'
    $name = $name -replace '-+', '-'
    return $name.Trim('-')
}

function Resolve-ContentDepartment {
    param([string]$Department, [string]$Title)
    $text = "$Department $Title"
    switch -Regex ($text) {
        'HR|Human Resources|People|Salary|Workforce' { return 'HR' }
        'Finance|Sales|Revenue|QBR|Commercial' { return 'Sales' }
        'Legal|Lawyer|Contract|Privacy' { return 'Legal' }
        'Data|Engineering|Platform|IT|Security|Cyber|Operations|Customer' { return 'Engineering' }
        default { return 'Sales' }
    }
}

function ConvertTo-AAPlainString {
    param($Value)
    if ($null -eq $Value) { return $null }

    $text = ([string]$Value).Trim()
    if ($text -match '^".*"$') {
        try { $text = [string]($text | ConvertFrom-Json) }
        catch { $text = $text.Trim('"') }
    }

    return $text.Trim().Trim('"')
}

function Get-KeyVaultSecretValue {
    param([string]$VaultName, [string]$SecretName)
    # Automation variables are stored through ARM as JSON literals. Depending on
    # runtime behavior, Get-AutomationVariable can return either the raw string
    # or a quoted JSON string. Normalize both shapes before calling Key Vault.
    $cleanVaultName = ConvertTo-AAPlainString $VaultName
    $cleanSecretName = ConvertTo-AAPlainString $SecretName

    if ([string]::IsNullOrWhiteSpace($cleanVaultName) -or [string]::IsNullOrWhiteSpace($cleanSecretName)) {
        Write-Warning "  [KV] Empty vault or secret name. Vault='$cleanVaultName' Secret='$cleanSecretName'"
        return $null
    }

    try {
        $kvToken = (Get-AzAccessToken -ResourceUrl 'https://vault.azure.net' -ErrorAction Stop).Token
        if ($kvToken -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($kvToken)
            try { $kvToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $kvToken = ConvertTo-AAPlainString $kvToken
        $headers = @{ Authorization = "Bearer $kvToken" }
        $encodedSecretName = [System.Uri]::EscapeDataString($cleanSecretName)
        $secretUri = "https://${cleanVaultName}.vault.azure.net/secrets/${encodedSecretName}?api-version=7.4"
        $secret = Invoke-RestMethod -Method GET `
            -Uri $secretUri `
            -Headers $headers -ErrorAction Stop
        Write-Verbose "  [KV] Secret '$cleanSecretName' read from '$cleanVaultName' (length=$($secret.value.Length))"
        return $secret.value
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "  [KV] Failed to read secret '$cleanSecretName' from vault '$cleanVaultName': $details"
        return $null
    }
}

# SharePoint site ID -- resolved dynamically at first run
$spoSiteId      = Get-AutomationVariable -Name 'AgentSpoSiteId' -ErrorAction SilentlyContinue
$teamsGroupId   = Get-AutomationVariable -Name 'AgentTeamsGroupId' -ErrorAction SilentlyContinue
$teamsChannelsJson = Get-AutomationVariable -Name 'AgentTeamsChannels' -ErrorAction SilentlyContinue
$collaborationSitesJson = Get-AutomationVariable -Name 'AgentCollaborationSites' -ErrorAction SilentlyContinue
$liveDemoSiteId = Get-AutomationVariable -Name 'AgentLiveDemoSiteId' -ErrorAction SilentlyContinue
$liveDemoSiteUrl = Get-AutomationVariable -Name 'AgentLiveDemoSiteUrl' -ErrorAction SilentlyContinue
$liveDemoRootFolder = Get-AutomationVariable -Name 'AgentLiveDemoRootFolder' -ErrorAction SilentlyContinue
if (-not $liveDemoRootFolder) { $liveDemoRootFolder = 'Purview-Defender-SeedContent' }
$collaborationSites = $null
if ($collaborationSitesJson) {
    try { $collaborationSites = $collaborationSitesJson | ConvertFrom-Json; Write-Output "Collaboration sites loaded from Automation variable" }
    catch { Write-Warning "Failed to parse AgentCollaborationSites: $($_.Exception.Message)" }
}
if ($liveDemoSiteId) {
    Write-Output "Live demo site loaded: $liveDemoSiteId ($liveDemoRootFolder)"
}
$externalAiServices = @()
if ($agentConfig.PSObject.Properties.Name -contains 'externalAiServices' -and $agentConfig.externalAiServices) {
    $externalAiServices = @($agentConfig.externalAiServices)
}
$externalAiRuntime = $null
if ($agentConfig.PSObject.Properties.Name -contains 'externalAiRuntime' -and $agentConfig.externalAiRuntime) {
    $externalAiRuntime = $agentConfig.externalAiRuntime
}

# Locale (country-specific file types, scan templates, PII generators)
$localeJson = Get-AutomationVariable -Name 'AgentLocale' -ErrorAction SilentlyContinue
$locale = $null
if ($localeJson) {
    try { $locale = $localeJson | ConvertFrom-Json; Write-Output "Locale loaded: $($locale.country) ($($locale.companyDescription))" }
    catch { Write-Warning "Failed to parse AgentLocale: $($_.Exception.Message)" }
}
$country = if ($locale) { $locale.country } elseif ($agentConfig.tenant.country) { $agentConfig.tenant.country } else { 'FR' }
$companyDesc = if ($locale) { $locale.companyDescription } else { 'a global company' }

# Fabric / OneLake settings
$fabricEnabled      = $agentConfig.infrastructure.fabricEnabled -eq $true
$fabricWorkspaceId  = Get-AutomationVariable -Name 'AgentFabricWorkspaceId' -ErrorAction SilentlyContinue
$fabricLakehouseId  = Get-AutomationVariable -Name 'AgentFabricLakehouseId' -ErrorAction SilentlyContinue

# SIT precision reference (from Automation variable, with hardcoded fallback below)
$sitReferenceFromVar = Get-AutomationVariable -Name 'AgentSitReference' -ErrorAction SilentlyContinue

# Sensitivity label mapping: file type -> label name per department
# Labels are resolved at runtime from Graph Beta API
$labelRules = @{
    HR = @{
        High = @('Paie_Mensuelle','Fiche_Employe','DPAE_Declaration','Registre_Personnel','Entretien_Annuel')
        HighLabel    = 'Conf-HR'
        DefaultLabel = 'Confidential/All Employees'
    }
    Finance = @{
        High = @('Virements_Fournisseurs','DSN_Mensuelle','Facture')
        HighLabel    = 'Conf-Finance'
        DefaultLabel = 'Confidential/All Employees'
    }
    Legal = @{
        High = @('Audit_CNIL','Contentieux','Contrat_CDI')
        HighLabel    = 'Highly Confidential/All Employees'
        DefaultLabel = 'Confidential/All Employees'
    }
    Engineering = @{
        High = @('TestData_PII','Incident_Report','Code_Review')
        HighLabel    = 'Confidential/All Employees'
        DefaultLabel = 'General/All Employees'
    }
    Sales = @{
        High = @('Pipeline_Commercial','Commissions','Proposition_Commerciale')
        HighLabel    = 'Confidential/All Employees'
        DefaultLabel = 'Confidential/All Employees'
    }
}

# DLP policy names for awareness context in emails and Teams posts
$dlpPolicies = @{
    HR          = 'Endpoint Policy, EXO Policy'
    Finance     = 'SPO Policy, EXO Policy'
    Legal       = 'SPO Policy, EXO Policy'
    Engineering = 'Teams Policy, Endpoint Policy'
    Sales       = 'EXO Policy, SPO Policy'
}

# =============================================================================
# SIT PRECISION REFERENCE (injected into all agent prompts)
# Uses Automation variable if available, otherwise falls back to this block.
# =============================================================================
if ($sitReferenceFromVar) {
    $sitReference = $sitReferenceFromVar
    Write-Output "SIT reference loaded from Automation variable ($($sitReference.Length) chars)"
} else {
    Write-Output "[WARN] No AgentSitReference variable -- using hardcoded fallback"
    $sitReference = @'

=== MANDATORY DATA FORMAT RULES (follow EXACTLY) ===

FRENCH NIR (numero de securite sociale / INSEE):
- Format: exactly 15 consecutive digits OR 13 digits + space + 2 digits
- Structure: S AA MM DDD CCC NNN KK (sex, birth year, month, dept, commune, order, checksum)
- MUST include a keyword within 300 characters: "numero de securite sociale", "NIR", "code secu", "securite sociale", "numero d'assurance"
- Examples: 2 85 07 75 123 456 78, 185077512345678, 1 93 11 99 345 234 12
- Generate 3-8 different NIR values per document. Vary the structure.

FRENCH IBAN (International Banking Account Number):
- Format: FR76 + 23 alphanumeric characters (total 27 chars with country+check)
- Structure: FR76 BBBBB GGGGG CCCCCCCCCC KK (bank, branch, account, check)
- No keyword needed (detected by pattern only)
- Examples: FR76 3000 6000 0112 3456 7890 189, FR76 1234 5678 9012 3456 7890 123
- Always start with FR76. Use spaces between groups of 4.

FRENCH TAX ID (numero d'identification fiscale / SPI):
- Format: exactly 13 digits, first digit must be 0, 1, 2, or 3
- MUST include a keyword: "numero d'identification fiscale", "tax id", "tax number", "numero fiscal", "SPI"
- Examples: 0 12 34 567 890 12, 1234567890123, 3 21 65 498 732 10

EU DEBIT CARD NUMBER:
- Format: 16 digits (groups of 4)
- Include keyword: "carte bancaire", "carte de debit", "card number"
- Examples: 4532 0123 4567 8901

PERSON NAME (French):
- Use realistic French first + last names: Jean Dupont, Marie Martin, Pierre Durand, Sophie Leblanc
- Vary names across documents

EMAIL ADDRESS:
- Format: prenom.nom@entreprise.fr or prenom.nom@gmail.com
- Examples: jean.dupont@corplab.fr, marie.martin@finance.corplab.fr

FRENCH PHONE NUMBER:
- Format: 06 XX XX XX XX or 07 XX XX XX XX (mobile), 01 XX XX XX XX (landline)
- Examples: 06 12 34 56 78, 01 45 67 89 00

CRITICAL RULES:
- Every document MUST contain at least 2 NIR values AND 2 IBAN values
- Place the keyword ("numero de securite sociale", "IBAN") within 300 characters of the data
- Mix formats: some with spaces, some without
- Never use placeholder X characters. Always generate complete fake numbers.
'@
}

# =============================================================================
# BUILD AGENTS FROM CONFIG (parameterized from agents.json)
# Uses List<T> instead of += to avoid O(n^2) array reallocation.
# Also builds $agentLookup hashtable for O(1) lookups in thread execution.
# =============================================================================
$agentList = [System.Collections.Generic.List[hashtable]]::new()
$agentLookup = @{}  # SAM -> agent hashtable (O(1) lookup for email/thread dispatch)

foreach ($ac in $agentConfig.agents) {
    # Build SIT-aware system prompt per agent
    $promptText = @"
You are $($ac.displayName), $($ac.jobTitle) at $companyDesc.
Style: $($ac.style).
Topics: $($ac.topics -join ', ').

PII REQUIREMENTS:
- Use the locale-specific sensitive data rules provided below. For the US locale, prefer SSN, bank routing/account numbers, EIN, ITIN, driver's license, passport, and phone/email values.
- Use realistic workplace names, emails, phone numbers, file names, and business context.
- Include sensitive data only when the activity or scenario calls for it.
Write in English. Never mention you are an AI.
"@

    $agent = @{
        Sam            = $ac.sam
        Upn            = Get-AgentUpn -AgentConfigItem $ac -Domain $domain
        SecretName     = Get-AgentSecretName -AgentConfigItem $ac -Domain $domain
        Name           = $ac.displayName
        Dept           = $ac.department
        ContentDept    = Resolve-ContentDepartment -Department $ac.department -Title $ac.jobTitle
        Title          = $ac.jobTitle
        StartHour      = $ac.workingHours.start
        EndHour        = $ac.workingHours.end
        Style          = $ac.style
        Topics         = $ac.topics
        FilesPerDay    = @($ac.filesPerDay[0], $ac.filesPerDay[1])
        EmailsPerDay   = @($ac.emailsPerDay[0], $ac.emailsPerDay[1])
        Workload       = if ($ac.workload) { $ac.workload } else { 'SPO' }
        CopilotLicense = [bool]$ac.copilotLicense
        Prompt         = $promptText
    }
    $agentList.Add($agent)
    $agentLookup[$ac.sam] = $agent
}
$agents = $agentList.ToArray()
Write-Output "Loaded $($agents.Count) agents from config ($($agentLookup.Count) in lookup table)."

# =============================================================================
# CROSS-DEPARTMENT EMAIL SCENARIOS
# =============================================================================
$emailScenarios = @(
    @{ From='ana.rodriguez';      To='marcus.olsson';    Context='IT Security sends a DLP investigation summary. Include file names, alert IDs, user UPNs, endpoint names, and recommended containment actions. Mention whether Defender XDR escalation is required.' }
    @{ From='carlos.delgado';     To='priya.sharma';     Context='Data Analytics shares a dashboard extract for model validation. Include sales metrics, HR trend fields, data quality notes, and a warning that some draft fields may contain sensitive workforce planning data.' }
    @{ From='david.chen';         To='emily.johnson';    Context='Customer Operations requests legal guidance for a customer escalation. Include case IDs, customer contact details, contract references, support timeline, and business impact.' }
    @{ From='james.wilson';       To='alexander.meyer';  Context='Operations sends a QBR readiness note. Include operational metrics, delivery risks, vendor constraints, and three executive decisions needed before the meeting.' }
    @{ From='marcus.olsson';      To='ana.rodriguez';    Context='Cybersecurity reports a potential oversharing incident. Include SharePoint/OneDrive locations, affected departments, DLP policy names, and recommended remediation.' }
    @{ From='alexander.meyer';    To='james.wilson';     Context='The CEO asks for an executive summary of operational performance. Request a concise version suitable for Copilot summarization and board review.' }
    @{ From='diego.martinez';     To='james.wilson';     Context='Sales sends QBR pipeline details. Include client names, opportunity stages, forecast amounts in USD, close risks, and follow-up owners.' }
    @{ From='emily.johnson';      To='david.chen';       Context='Legal replies to a customer escalation. Include a privileged legal assessment, contractual risk, recommended customer response, and a note not to share externally.' }
    @{ From='laura.gomez';        To='ana.rodriguez';    Context='HR sends a salary planning data protection question. Include employee names, salary bands, SSN values with the keyword social security number, and bank routing/account examples for direct deposit.' }
    @{ From='priya.sharma';       To='diego.martinez';   Context='Data Science reports a Copilot-assisted insight. Include sales trend findings, possible restructuring signals discovered in overshared drafts, and questions about appropriate access.' }
    @{ From='sofia.lopez';        To='laura.gomez';      Context='Project Management follows up on the HR oversharing remediation plan. Include milestones, owners, and a request to restrict broad sharing before stakeholder review.' }
    @{ From='miguel.santos';      To='ana.rodriguez';    Context='Platform Engineering reports a configuration issue. Include system names, API endpoints, fake connection strings, log paths, and a risk note about secrets in documentation.' }
)

# Pre-build per-agent email scenario lookup (O(1) dispatch in main loop)
$emailScenariosBySam = @{}
foreach ($es in $emailScenarios) {
    if (-not $emailScenariosBySam.ContainsKey($es.From)) {
        $emailScenariosBySam[$es.From] = [System.Collections.Generic.List[hashtable]]::new()
    }
    $emailScenariosBySam[$es.From].Add($es)
}

# =============================================================================
# MULTI-TURN EMAIL CONVERSATIONS (loaded from config variable)
# =============================================================================
# Each thread simulates a realistic multi-message discussion where PII
# accumulates through replies and forwards. AI generates each message
# based on the previous one, creating natural conversation flow.
# Threads are defined in config/email-threads.json and stored as an
# Automation variable (AgentEmailThreads) by Deploy-Runbook.ps1.
$emailThreadsJson = Get-AutomationVariable -Name 'AgentEmailThreads' -ErrorAction SilentlyContinue
if ($emailThreadsJson) {
    $rawThreads = $emailThreadsJson | ConvertFrom-Json
    $threadList = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($t in $rawThreads) {
        $msgs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($m in $t.messages) {
            $msgs.Add(@{ From=$m.from; To=$m.to; Instruction=$m.instruction })
        }
        $threadList.Add(@{ ThreadName=$t.threadName; Messages=$msgs.ToArray() })
    }
    $emailThreads = $threadList.ToArray()
} else {
    Write-Output "[WARN] AgentEmailThreads variable not found -- multi-turn threads disabled"
    $emailThreads = @()
}

# =============================================================================
# COPILOT M365 QUERY CONFIG (built dynamically from agent config)
# =============================================================================
# System prompts per agent for generating contextual Copilot search queries.
# Azure OpenAI generates unique, pertinent queries each run based on the persona.
# Only agents with copilotLicense=true get Copilot prompts.
$deptSearchTopics = @{
    HR          = 'salary planning, employee files, onboarding checklists, social security numbers, bank routing and account data, workforce planning'
    Finance     = 'supplier payments, bank accounts, budgets, expense reports, invoices, tax identifiers, quarterly reports, cost centers'
    Legal       = 'contracts, privacy reviews, regulatory registers, litigation files, NDA reviews, legal opinions, customer escalation risk'
    Engineering = 'test datasets with PII, API specifications, debug logs, connection strings, platform incidents, security investigations'
    Sales       = 'client proposals, commercial pipeline, commissions, QBR materials, customer contacts, revenue forecasts, deal summaries'
}
$deptPiiHint = @{
    HR          = 'Mix specific queries (e.g. searching for a specific employee or month) with broad queries.'
    Finance     = 'Include at least one query mentioning bank account or tax details.'
    Legal       = 'Include at least one query about personal data or contract risk.'
    Engineering = 'Include at least one query about sensitive data in test environments.'
    Sales       = 'Include at least one query about client bank details or contract amounts.'
}
$liveDemoSearchHint = if ($liveDemoSiteUrl) {
    "If relevant, include one query that can discover seeded live demo documents in $liveDemoSiteUrl under $liveDemoRootFolder, especially documents mentioning Alexander Meyer, Emily Johnson, James Wilson, Marcus Olsson, workforce planning, DLP, Sentinel, or social security number."
} else {
    "If relevant, include one query that can discover seeded live demo documents named Alexander_board, Emily_ai_data, James_operations, Marcus_dlp, or Workforce_Planning."
}
$copilotPrompts = @{}
foreach ($a in $agents) {
    if ($a.CopilotLicense) {
        $dept = $a.ContentDept
        $topics = $deptSearchTopics[$dept]
        $hint   = $deptPiiHint[$dept]
        $langNote = 'in English'
        $copilotPrompts[$a.Sam] = @"
You are $($a.Name), $($a.Title). Generate 3 realistic SharePoint search queries
for Microsoft 365 Copilot to find $($dept.ToLower()) documents.
Your queries must be $langNote and relate to: $topics.
$hint
$liveDemoSearchHint
Output ONLY the queries, one per line, no numbering, no explanation.
"@
    }
}

# =============================================================================
# FILE TYPE TEMPLATES (document types per department)
# Locale-aware: HR/Finance/Legal/Sales loaded from AgentLocale variable.
# Engineering templates are universal (data engineering patterns, same everywhere).
# =============================================================================

# Load locale-specific file types for business departments
$fileTypes = @{}
if ($locale -and $locale.fileTypes) {
    foreach ($dept in @('HR','Finance','Legal','Sales')) {
        if ($locale.fileTypes.$dept) {
            $fileTypes[$dept] = @($locale.fileTypes.$dept | ForEach-Object {
                @{ Type = $_.Type; Ext = $_.Ext; Prompt = $_.Prompt }
            })
        }
    }
    Write-Output "File types loaded from $country locale: $($fileTypes.Keys -join ', ')"
}

# Fallback: if no locale or missing departments, use English US defaults
if (-not $fileTypes['HR']) {
    $fileTypes['HR'] = @(
        @{ Type='Paie_Mensuelle';       Ext='.csv'; Prompt='Generate a monthly payroll CSV with semicolons: Employe;NIR;IBAN;Salaire_Brut;Date. Include 6-10 rows.' }
        @{ Type='Fiche_Employe';        Ext='.txt'; Prompt='Generate a confidential employee file with full name, NIR, IBAN, annual salary, home address, start date.' }
        @{ Type='Onboarding_Checklist'; Ext='.txt'; Prompt='Generate an onboarding checklist with NIR, IBAN for salary, manager name, equipment list.' }
        @{ Type='Rapport_Absences';     Ext='.csv'; Prompt='Generate an absence report CSV: Employe;Type;Debut;Fin;NIR. Include 5-8 rows.' }
        @{ Type='DPAE_Declaration';     Ext='.txt'; Prompt='Generate a DPAE with employee NIR, birth date, IBAN, contract type (CDI/CDD).' }
        @{ Type='Entretien_Annuel';     Ext='.txt'; Prompt='Generate an annual review with employee name, NIR, objectives, salary, IBAN for bonus.' }
        @{ Type='Registre_Personnel';   Ext='.csv'; Prompt='Generate a personnel register: Nom;Prenom;NIR;Date_Entree;Poste;IBAN;Salaire. 8-12 rows.' }
        @{ Type='Scan_Bulletin_Paie';   Ext='.png'; Prompt='SCAN' }
        @{ Type='Scan_Badge_Employe';   Ext='.png'; Prompt='SCAN' }
    )
}
if (-not $fileTypes['Finance']) {
    $fileTypes['Finance'] = @(
        @{ Type='Virements_Fournisseurs'; Ext='.csv'; Prompt='Generate a supplier payment CSV: Fournisseur;IBAN;Montant;Devise;Reference. 6-8 suppliers.' }
        @{ Type='Rapport_Financier';     Ext='.txt'; Prompt='Generate a quarterly financial report with revenue, costs, treasury IBAN, EU VAT number.' }
        @{ Type='DSN_Mensuelle';         Ext='.csv'; Prompt='Generate a DSN CSV: Employe;NIR;Net_Imposable;Prelevement;IBAN. 5-8 rows.' }
        @{ Type='Notes_Frais';           Ext='.txt'; Prompt='Generate an expense report with employee name, reimbursement IBAN, itemized expenses.' }
        @{ Type='Budget_Previsionnel';   Ext='.txt'; Prompt='Generate a budget forecast with salary costs, treasury IBAN, department breakdowns.' }
        @{ Type='Facture';               Ext='.txt'; Prompt='Generate an invoice with supplier details, IBAN, VAT number, line items, total HT/TTC.' }
        @{ Type='Scan_Facture';          Ext='.png'; Prompt='SCAN' }
    )
}
if (-not $fileTypes['Legal']) {
    $fileTypes['Legal'] = @(
        @{ Type='Audit_CNIL';          Ext='.txt'; Prompt='Generate a CNIL audit report listing 4-6 persons with their NIR, findings, corrective actions.' }
        @{ Type='Contrat_CDI';         Ext='.txt'; Prompt='Generate an employment contract (CDI) with employee NIR, IBAN, salary, working hours.' }
        @{ Type='Registre_RGPD';       Ext='.txt'; Prompt='Generate a GDPR register entry for payroll: data types (NIR,IBAN), legal basis, retention.' }
        @{ Type='Contentieux';         Ext='.txt'; Prompt='Generate a litigation file with plaintiff NIR, claimed amount, case timeline, settlement IBAN.' }
        @{ Type='Avis_Juridique';      Ext='.txt'; Prompt='Generate a legal opinion about data protection, referencing specific employee NIR in breach.' }
        @{ Type='NDA';                 Ext='.txt'; Prompt='Generate an NDA with party names, addresses, confidential info description, penalty amounts.' }
    )
}
if (-not $fileTypes['Sales']) {
    $fileTypes['Sales'] = @(
        @{ Type='Pipeline_Commercial';  Ext='.csv'; Prompt='Generate a sales pipeline CSV: Client;Contact;Email;IBAN;Montant_Contrat. 5-8 prospects.' }
        @{ Type='Proposition_Commerciale'; Ext='.txt'; Prompt='Generate a commercial proposal with client details, payment IBAN, quote amount HT/TTC.' }
        @{ Type='Commissions';           Ext='.csv'; Prompt='Generate a commission report CSV: Commercial;Client;CA;Commission;IBAN_Commission. 4-6 rows.' }
        @{ Type='CR_Reunion_Client';     Ext='.txt'; Prompt='Generate client meeting notes with attendees, budget, next steps, IBAN for advance.' }
        @{ Type='Liste_Prospects';       Ext='.txt'; Prompt='Generate a prospect list with company names, contact, email, phone, estimated value.' }
        @{ Type='RFP_Response';          Ext='.txt'; Prompt='Generate an RFP response with credentials, pricing, bank details (IBAN), references.' }
    )
}

# Engineering file types are UNIVERSAL (data engineering and platform patterns)
$fileTypes['Engineering'] = @(
        @{ Type='TestData_PII';          Ext='.csv';  Prompt='Generate a test data CSV: EmployeeId;Name;SSN;Bank_Routing;Bank_Account;Email;Phone;Department;Birth_Date;Address. Include 8-15 rows with realistic fake US PII. Use the keyword social security number near SSN values.' }
        @{ Type='Customer_Dataset';      Ext='.csv';  Prompt='Generate a customer dataset CSV: CustomerId;Company;Contact_Name;Contact_Email;Phone;EIN;Contract_Value;Region;Account_Manager. Include 10-15 realistic business records.' }
        @{ Type='Data_Access_Audit';     Ext='.csv';  Prompt='Generate a data access audit log CSV: Timestamp;User;Action;Table;Columns_Accessed;Row_Count;Source_IP. Include suspicious patterns such as bulk exports, after-hours access, and HR salary table reads.' }
        @{ Type='Payroll_Dataset';       Ext='.csv';  Prompt='Generate a payroll dataset CSV: EmployeeId;Name;SSN;Bank_Routing;Bank_Account;Gross_Pay;Net_Pay;Payment_Date;Tax_ID;Address. Include 15-25 rows with realistic fake US PII.' }
        @{ Type='Vendor_Master_Data';    Ext='.csv';  Prompt='Generate a vendor master data CSV: Vendor;EIN;Bank_Routing;Bank_Account;Contact_Email;Phone;Address;Annual_Spend;Payment_Terms. Include 12-18 vendors.' }
        @{ Type='PII_Anomaly_Report';    Ext='.csv';  Prompt='Generate a PII anomaly detection CSV: Detection_Date;Source;PII_Type;Detected_Value;Column;Severity;Status. Include SSN, routing number, account number, credit card, and email examples.' }
        @{ Type='Schema_JSON';           Ext='.json'; Prompt='Generate a JSON schema for an employee data model with fields employeeId, fullName, ssn, bankRouting, bankAccount, email, phone, department, salary. Include example values with realistic fake PII.' }
        @{ Type='Pipeline_Config';       Ext='.json'; Prompt='Generate a JSON ETL pipeline configuration with extract, transform, mask PII, validate email format, and load stages. Include fake connection strings, retry policy, schedule, and column mappings.' }
        @{ Type='OpenAPI_Spec';          Ext='.json'; Prompt='Generate an OpenAPI 3.0 JSON spec for an HR payroll API. Include request/response schemas with SSN, bank routing/account, salary, and payment date fields.' }
        @{ Type='Masking_Config';        Ext='.json'; Prompt='Generate a JSON data masking configuration with rules for SSN, bank account, routing number, email, phone, and credit card. Include sample input/output pairs.' }
        @{ Type='Security_Incident';     Ext='.md';   Prompt='Generate a Markdown security incident report with timeline, impact, root cause, containment, remediation, and KQL queries. Include fake SSN and bank account examples found in logs.' }
        @{ Type='Architecture_Doc';      Ext='.md';   Prompt='Generate a Markdown architecture document for an HR analytics platform with sections for sources, transformations, storage, consumption, identity, logging, and a Mermaid diagram.' }
        @{ Type='Data_Quality_Report';   Ext='.md';   Prompt='Generate a Markdown data quality report with metrics, anomalies, trend analysis, corrective actions, and a table of sensitive data quality findings.' }
        @{ Type='Dashboard_DQ';          Ext='.html'; Prompt='Generate an HTML data quality dashboard with inline CSS, metric cards, anomaly table, and data lineage footer. Include examples of sensitive data findings.' }
        @{ Type='Employee_Profile_Card'; Ext='.html'; Prompt='Generate an HTML employee profile card with inline CSS. Include employee ID, department, job title, SSN, bank routing/account, email, phone, and address using realistic fake data.' }
        @{ Type='Lineage_Diagram';       Ext='.svg';  Prompt='Generate a valid SVG data lineage diagram showing HR source systems -> ETL pipeline -> Fabric Lakehouse -> Power BI report. Include field labels such as SSN, bankAccount, email, salary.' }
        @{ Type='Debug_Log';             Ext='.txt';  Prompt='Generate a debug log with ISO timestamps showing ETL processing of employee records. Include INFO/WARN/ERROR lines, masked and unmasked PII examples, and failed validation records.' }
        @{ Type='Migration_Log';         Ext='.txt';  Prompt='Generate a data migration log from a legacy HR system to a lakehouse. Include migrated record IDs, SSN validation, bank account validation, status OK/FAILED, and realistic fake values.' }
        @{ Type='ACH_Payment_XML';       Ext='.xml';  Prompt='Generate a valid XML payment batch with employee/vendor names, bank routing numbers, bank account numbers, amounts, references, and creation date.' }
    )
# =============================================================================
# SCANNED DOCUMENT IMAGE GENERATION (PNG with PII for OCR detection)
# Locale-aware: uses $locale for labels, PII formats, bank details, tax rates.
# =============================================================================
Add-Type -AssemblyName System.Drawing

function New-ScanImage {
    param([string]$Type, [string]$AgentName, [string]$Dept)
    $bmp = New-Object System.Drawing.Bitmap(850, 1100)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::FromArgb(248, 245, 238))

    $titleFont  = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
    $headerFont = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)
    $bodyFont   = New-Object System.Drawing.Font("Courier New", 10)
    $smallFont  = New-Object System.Drawing.Font("Arial", 8)
    $black = [System.Drawing.Brushes]::Black
    $gray  = [System.Drawing.Brushes]::DarkGray
    $red   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 0, 0))
    $pen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 200, 200), 2)
    $g.DrawRectangle($pen, 30, 30, 790, 1040)

    # Locale-aware PII generation
    $sc = if ($locale -and $locale.scanTemplates) { $locale.scanTemplates } else { $null }
    $pii = if ($locale -and $locale.piiGenerators) { $locale.piiGenerators } else { $null }
    $cur = if ($locale) { $locale.currency } else { 'EUR' }
    $emailDom = if ($pii -and $pii.emailDomain) { $pii.emailDomain } else { 'corp.fr' }

    # Generate country-appropriate PII values
    switch ($country) {
        'US' {
            $idLabel = 'SSN'; $idValue = "$(Get-Random -Min 100 -Max 899)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000 -Max 9999)"
            $bankLabel = 'Routing'; $bankValue = "$(Get-Random -Min 100000000 -Max 999999999)"
            $bank2Label = 'Account'; $bank2Value = "$(Get-Random -Min 1000000000 -Max 9999999999)"
            $taxLabel = 'EIN'; $taxValue = "$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000000 -Max 9999999)"
            $phonePrefix = @('212','310','415','312') | Get-Random
            $phone = "($phonePrefix) $(Get-Random -Min 100 -Max 999)-$(Get-Random -Min 1000 -Max 9999)"
            $bankName = 'Chase Bank'; $bic = 'CHASUS33'; $taxRateLabel = 'Sales Tax'; $taxRate = 8.875; $supplierSuffix = 'LLC'
        }
        'UK' {
            $letters = 'ABCEGHJKLMNPRSTWXYZ'; $sl = $letters[(Get-Random -Max $letters.Length)]; $sl2 = $letters[(Get-Random -Max $letters.Length)]
            $idLabel = 'NI Number'; $idValue = "$sl$sl2 $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(@('A','B','C','D') | Get-Random)"
            $bankLabel = 'Sort Code'; $bankValue = "$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 10 -Max 99)"
            $bank2Label = 'Account'; $bank2Value = "$(Get-Random -Min 10000000 -Max 99999999)"
            $taxLabel = 'UTR'; $taxValue = "$(Get-Random -Min 1000000000 -Max 9999999999)"
            $phonePrefix = @('07700','07800') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 100000 -Max 999999)"
            $bankName = 'Barclays'; $bic = 'BARCGB22'; $taxRateLabel = 'VAT'; $taxRate = 20; $supplierSuffix = 'Ltd'
        }
        'DE' {
            $idLabel = 'Steuer-ID'; $idValue = -join ((0..10) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $deIban = -join ((0..17) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $bankLabel = 'IBAN'; $bankValue = "DE$($deIban.Substring(0,2)) $($deIban.Substring(2,4)) $($deIban.Substring(6,4)) $($deIban.Substring(10,4)) $($deIban.Substring(14,4))"
            $bank2Label = ''; $bank2Value = ''
            $taxLabel = 'SV-Nummer'; $taxValue = "$(Get-Random -Min 10 -Max 99) $(Get-Random -Min 100000 -Max 999999) $(Get-Random -Min 1 -Max 9)"
            $phonePrefix = @('0151','0160','0170') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 1000000 -Max 9999999)"
            $bankName = 'Deutsche Bank'; $bic = 'DEUTDEFF'; $taxRateLabel = 'MwSt'; $taxRate = 19; $supplierSuffix = 'GmbH'
        }
        default {
            # FR (default)
            $nirPrefix = @('1','2') | Get-Random; $nirBody = -join ((0..12) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $idLabel = 'NIR'; $idValue = "$nirPrefix $($nirBody.Substring(0,2)) $($nirBody.Substring(2,2)) $($nirBody.Substring(4,2)) $($nirBody.Substring(6,3)) $($nirBody.Substring(9,3)) $($nirBody.Substring(12,1))$(Get-Random -Min 10 -Max 99)"
            $ibanBody = -join ((0..19) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $bankLabel = 'IBAN'; $bankValue = "FR76 $($ibanBody.Substring(0,4)) $($ibanBody.Substring(4,4)) $($ibanBody.Substring(8,4)) $($ibanBody.Substring(12,4)) $($ibanBody.Substring(16,4))"
            $bank2Label = ''; $bank2Value = ''
            $taxLabel = 'N. Fiscal'; $taxValue = -join ((0..12) | ForEach-Object { Get-Random -Min 0 -Max 10 })
            $phonePrefix = @('06','07') | Get-Random; $phone = "$phonePrefix $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99) $(Get-Random -Min 10 -Max 99)"
            $bankName = 'BNP Paribas'; $bic = 'BNPAFRPP'; $taxRateLabel = 'TVA'; $taxRate = 20; $supplierSuffix = 'SAS'
        }
    }

    $nameParts = $AgentName -split ' '
    $nom = if ($nameParts.Count -ge 2) { "$($nameParts[-1]), $($nameParts[0])" } else { $AgentName }
    $email = "$($nameParts[0].ToLower()[0])$($nameParts[-1].ToLower())@$emailDom"
    $date = Get-Date -Format 'MMMM yyyy'
    $salBrut = Get-Random -Min 2800 -Max 5500

    # Resolve scan type to generic category (locale scan types may have different names)
    $scanCategory = if ($Type -match 'Paie|Pay|Lohn|Payslip') { 'payslip' }
                    elseif ($Type -match 'Badge|Ausweis') { 'badge' }
                    elseif ($Type -match 'Facture|Invoice|Rechnung') { 'invoice' }
                    else { 'payslip' }

    $payslipTitle = if ($sc -and $sc.payslip) { $sc.payslip.title } else { 'PAYSLIP' }
    $badgeTitle   = if ($sc -and $sc.badge) { $sc.badge.title } else { 'EMPLOYEE BADGE' }
    $invoiceTitle = if ($sc -and $sc.invoice) { $sc.invoice.title } else { 'INVOICE' }

    switch ($scanCategory) {
        'payslip' {
            $g.DrawString($payslipTitle, $titleFont, $black, 250, 50)
            $g.DrawString("$date", $headerFont, $gray, 330, 80)
            $g.DrawLine($pen, 50, 110, 800, 110)
            $y = 130
            $g.DrawString("Name:         $nom", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Department:   $Dept", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${idLabel}:$((' ' * [Math]::Max(1, 14 - $idLabel.Length)))$idValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${taxLabel}:$((' ' * [Math]::Max(1, 14 - $taxLabel.Length)))$taxValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("${bankLabel}:$((' ' * [Math]::Max(1, 14 - $bankLabel.Length)))$bankValue", $bodyFont, $black, 60, $y); $y += 22
            if ($bank2Label) { $g.DrawString("${bank2Label}:$((' ' * [Math]::Max(1, 14 - $bank2Label.Length)))$bank2Value", $bodyFont, $black, 60, $y); $y += 22 }
            $y += 10; $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("Gross:        $($salBrut.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $deductions = [Math]::Round($salBrut * 0.34, 2)
            $net = [Math]::Round($salBrut - $deductions, 2)
            $g.DrawString("Deductions:   -$($deductions.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Net Pay:      $($net.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawString("Bank: $bankName | BIC: $bic", $bodyFont, $gray, 60, $y)
        }
        'badge' {
            $g.DrawString($badgeTitle, $titleFont, $red, 150, 50)
            $g.DrawLine($pen, 50, 90, 800, 90)
            $g.FillRectangle([System.Drawing.Brushes]::LightGray, 60, 120, 200, 250)
            $g.DrawString("PHOTO", $headerFont, $gray, 120, 230)
            $g.DrawRectangle($pen, 60, 120, 200, 250)
            $y = 130
            $g.DrawString("Name:    $nom", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Dept:    $Dept", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${idLabel}:$((' ' * [Math]::Max(1, 9 - $idLabel.Length)))$idValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${taxLabel}:$((' ' * [Math]::Max(1, 9 - $taxLabel.Length)))$taxValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("${bankLabel}:$((' ' * [Math]::Max(1, 9 - $bankLabel.Length)))$bankValue", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Email:   $email", $bodyFont, $black, 290, $y); $y += 28
            $g.DrawString("Phone:   $phone", $bodyFont, $black, 290, $y)
        }
        'invoice' {
            $g.DrawString($invoiceTitle, $titleFont, $black, 330, 50)
            $g.DrawString("N. INV-2026-$(Get-Random -Min 1000 -Max 9999)", $headerFont, $gray, 280, 80)
            $g.DrawLine($pen, 50, 110, 800, 110)
            $y = 130
            $g.DrawString("$supplierSuffix TechServices | ${taxLabel}: $($taxRateLabel.Substring(0,2))$(Get-Random -Min 10 -Max 99) $(Get-Random -Min 100000000 -Max 999999999)", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawString("TO: $nom | Dept: $Dept", $bodyFont, $black, 60, $y); $y += 30
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 20
            $m1 = Get-Random -Min 500 -Max 5000; $m2 = Get-Random -Min 200 -Max 2000
            $g.DrawString("IT Consulting Services      $($m1.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("Annual Software License     $($m2.ToString('N2')) $cur", $bodyFont, $black, 60, $y); $y += 30
            $total = $m1 + $m2; $tax = [Math]::Round($total * $taxRate / 100, 2)
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("Subtotal:   $($total.ToString('N2')) $cur", $bodyFont, $black, 400, $y); $y += 22
            $g.DrawString("$taxRateLabel ${taxRate}%:  $($tax.ToString('N2')) $cur", $bodyFont, $black, 400, $y); $y += 22
            $g.DrawString("TOTAL:      $([Math]::Round($total + $tax, 2).ToString('N2')) $cur", $headerFont, $black, 380, $y); $y += 40
            $g.DrawLine($pen, 50, $y, 800, $y); $y += 15
            $g.DrawString("${bankLabel}: $bankValue", $bodyFont, $black, 60, $y); $y += 22
            $g.DrawString("BIC: $bic", $bodyFont, $black, 60, $y)
        }
    }

    $g.DrawString("Scanned $(Get-Date -Format 'dd/MM/yyyy HH:mm')", $smallFont, $gray, 280, 1050)

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $g.Dispose(); $bmp.Dispose(); $ms.Dispose()
    return ,$bytes
}

# =============================================================================
# AUTHENTICATION
# =============================================================================
function Get-ROPCToken {
    param([string]$Username, [string]$Password, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $Username = ConvertTo-AAPlainString $Username
    $Password = ConvertTo-AAPlainString $Password
    $TenantId = ConvertTo-AAPlainString $TenantId
    $ClientId = ConvertTo-AAPlainString $ClientId
    $ClientSecret = ConvertTo-AAPlainString $ClientSecret

    # Password grant still produces a delegated user token. .default consumes the
    # tenant-wide admin consent already granted to app-claudia-dataagent and avoids per-user
    # consent prompts that can happen with dynamic short scope names.
    $scopeAttempts = @(
        'https://graph.microsoft.com/.default',
        'openid offline_access Files.ReadWrite.All Sites.ReadWrite.All Mail.Send Chat.ReadWrite ChannelMessage.Send Team.ReadBasic.All Chat.Create User.Read'
    )
    $lastError = $null
    foreach ($scope in $scopeAttempts) {
        $body = @{
            grant_type    = 'password'
            client_id     = $ClientId
            client_secret = $ClientSecret
            username      = $Username
            password      = $Password
            scope         = $scope
        }
        $encodedBody = ($body.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [System.Net.WebUtility]::UrlEncode([string]$_.Key), [System.Net.WebUtility]::UrlEncode([string]$_.Value)
        }) -join '&'
        try {
            Write-Verbose "  [AUTH] Requesting ROPC token for $Username (client=$ClientId, scope=$scope, secretLength=$($ClientSecret.Length))"
            $resp = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -ContentType 'application/x-www-form-urlencoded' -Body $encodedBody -ErrorAction Stop
            return $resp.access_token
        } catch {
            $lastError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        }
    }
    throw "ROPC token request failed for $Username. $lastError"
}

function Get-OneLakeToken {
    param([string]$Username, [string]$Password, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    # Separate ROPC token for OneLake (storage.azure.com audience)
    $Username = ConvertTo-AAPlainString $Username
    $Password = ConvertTo-AAPlainString $Password
    $TenantId = ConvertTo-AAPlainString $TenantId
    $ClientId = ConvertTo-AAPlainString $ClientId
    $ClientSecret = ConvertTo-AAPlainString $ClientSecret
    $body = @{
        grant_type    = 'password'
        client_id     = $ClientId
        client_secret = $ClientSecret
        username      = $Username
        password      = $Password
        scope         = 'https://storage.azure.com/.default'
    }
    $encodedBody = ($body.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [System.Net.WebUtility]::UrlEncode([string]$_.Key), [System.Net.WebUtility]::UrlEncode([string]$_.Value)
    }) -join '&'
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body $encodedBody -ErrorAction Stop
        $resp.access_token
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "OneLake token request failed for $Username. $details"
    }
}

function Write-OneLake {
    param([string]$Token, [string]$WorkspaceId, [string]$LakehouseId, [string]$Path, [byte[]]$Content)
    $baseUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$LakehouseId/Files/$Path"
    $headers = @{Authorization = "Bearer $Token"}
    # Step 1: Create file
    Invoke-RestMethod -Method PUT -Uri "$baseUri`?resource=file&overwrite=true" -Headers $headers -ContentType 'application/octet-stream' | Out-Null
    # Step 2: Append data
    Invoke-RestMethod -Method PATCH -Uri "$baseUri`?action=append&position=0" -Headers $headers -Body $Content -ContentType 'application/octet-stream' | Out-Null
    # Step 3: Flush
    Invoke-RestMethod -Method PATCH -Uri "$baseUri`?action=flush&position=$($Content.Length)" -Headers $headers | Out-Null
}

function ConvertTo-AASafeText {
    param([AllowNull()][string]$Text, [int]$MaxLength = 0)
    if ($null -eq $Text) { return '' }
    $clean = [regex]::Replace([string]$Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ')
    # Azure OpenAI and Graph occasionally reject unpaired surrogate characters
    # produced by model output or copied source content.
    $clean = [regex]::Replace($clean, '[\uD800-\uDFFF]', '')
    if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) {
        return $clean.Substring(0, $MaxLength)
    }
    return $clean
}

function ConvertTo-AAJsonBody {
    param([Parameter(Mandatory)]$Value, [int]$Depth = 20)
    $jsonParams = @{ Depth = $Depth; Compress = $true }
    if ((Get-Command ConvertTo-Json).Parameters.ContainsKey('EscapeHandling')) {
        $jsonParams.EscapeHandling = 'EscapeNonAscii'
    }
    $json = $Value | ConvertTo-Json @jsonParams
    return ,([System.Text.Encoding]::UTF8.GetBytes($json))
}

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function ConvertTo-AAXmlText {
    param([AllowNull()][string]$Text)
    return [System.Security.SecurityElement]::Escape((ConvertTo-AASafeText -Text $Text))
}

function Add-AAZipEntry {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$Name,
        [string]$Content
    )
    $entry = $Archive.CreateEntry($Name)
    $stream = $entry.Open()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function New-AADocxBytes {
    param([string]$Title, [string]$Content)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "aa-$([guid]::NewGuid().ToString('N')).docx")
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-AAZipEntry -Archive $archive -Name '[Content_Types].xml' -Content '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
            Add-AAZipEntry -Archive $archive -Name '_rels/.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            $paragraphs = [System.Collections.Generic.List[string]]::new()
            $paragraphs.Add("<w:p><w:r><w:t>$(ConvertTo-AAXmlText -Text $Title)</w:t></w:r></w:p>") | Out-Null
            foreach ($line in @($Content -split "`r?`n")) {
                $paragraphs.Add("<w:p><w:r><w:t>$(ConvertTo-AAXmlText -Text $line)</w:t></w:r></w:p>") | Out-Null
            }
            $documentXml = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + ($paragraphs -join '') + '<w:sectPr/></w:body></w:document>'
            Add-AAZipEntry -Archive $archive -Name 'word/document.xml' -Content $documentXml
        }
        finally {
            $archive.Dispose()
        }
        return ,[System.IO.File]::ReadAllBytes($path)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function New-AAXlsxBytes {
    param([string]$Title, [string]$Content)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "aa-$([guid]::NewGuid().ToString('N')).xlsx")
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            Add-AAZipEntry -Archive $archive -Name '[Content_Types].xml' -Content '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
            Add-AAZipEntry -Archive $archive -Name '_rels/.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
            Add-AAZipEntry -Archive $archive -Name 'xl/_rels/workbook.xml.rels' -Content '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
            Add-AAZipEntry -Archive $archive -Name 'xl/workbook.xml' -Content '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="AgentData" sheetId="1" r:id="rId1"/></sheets></workbook>'
            $rows = [System.Collections.Generic.List[string]]::new()
            $rowIndex = 1
            foreach ($line in @($Content -split "`r?`n" | Select-Object -First 80)) {
                $columns = @($line -split '[,;]' | Select-Object -First 12)
                if ($columns.Count -eq 0) { $columns = @($line) }
                $cells = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $colName = [char](65 + $i)
                    $cells.Add("<c r=`"$colName$rowIndex`" t=`"inlineStr`"><is><t>$(ConvertTo-AAXmlText -Text $columns[$i])</t></is></c>") | Out-Null
                }
                $rows.Add("<row r=`"$rowIndex`">$($cells -join '')</row>") | Out-Null
                $rowIndex++
            }
            if ($rows.Count -eq 0) {
                $rows.Add('<row r="1"><c r="A1" t="inlineStr"><is><t>Empty</t></is></c></row>') | Out-Null
            }
            $sheetXml = '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + ($rows -join '') + '</sheetData></worksheet>'
            Add-AAZipEntry -Archive $archive -Name 'xl/worksheets/sheet1.xml' -Content $sheetXml
        }
        finally {
            $archive.Dispose()
        }
        return ,[System.IO.File]::ReadAllBytes($path)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-AASensitivityLabelSupportedExtension {
    param([string]$Extension)
    return @('.docx','.xlsx','.pptx','.pdf') -contains ([string]$Extension).ToLowerInvariant()
}

function ConvertTo-AALabelFriendlyFile {
    param(
        [string]$Type,
        [string]$Extension,
        [string]$Content,
        [byte[]]$Bytes
    )
    $ext = ([string]$Extension).ToLowerInvariant()
    if (Test-AASensitivityLabelSupportedExtension -Extension $ext) {
        return @{ Ext = $ext; Bytes = $Bytes; Content = $Content; Converted = $false; OriginalExt = $ext }
    }

    $safeContent = if ([string]::IsNullOrWhiteSpace($Content)) {
        "Generated lab document for $Type.`nSSN social security number: 384-29-5187`nRouting number: 021000021`nAccount number: 492017388201"
    } else {
        $Content
    }

    if ($ext -eq '.csv') {
        return @{ Ext = '.xlsx'; Bytes = (New-AAXlsxBytes -Title $Type -Content $safeContent); Content = $safeContent; Converted = $true; OriginalExt = $ext }
    }

    return @{ Ext = '.docx'; Bytes = (New-AADocxBytes -Title $Type -Content $safeContent); Content = $safeContent; Converted = $true; OriginalExt = $ext }
}

function Invoke-Graph {
    param([string]$Token, [string]$Method = 'GET', [string]$Uri, $Body, [string]$ContentType = 'application/json')
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = $ContentType }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; ContentType = $ContentType }
    if ($Body) {
        if ($Body -is [byte[]]) { $params.Body = $Body }
        elseif ($Body -is [string]) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        else { $params.Body = ConvertTo-AAJsonBody -Value $Body -Depth 20 }
    }
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @params
        } catch {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
            $retryable = $statusCode -in @(429, 502, 503, 504)
            if ($retryable -and $attempt -lt $maxAttempts) {
                $delay = [math]::Pow(2, $attempt)  # 2s, 4s, 8s
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers.GetValues('Retry-After') | Select-Object -First 1 } catch { $retryAfter = $null }
                $retryAfterSeconds = 0
                if ($retryAfter -and [int]::TryParse([string]$retryAfter, [ref]$retryAfterSeconds)) { $delay = [math]::Max($retryAfterSeconds, $delay) }
                Write-Verbose "  [GRAPH] $Method $Uri returned $statusCode - retry $attempt/$($maxAttempts - 1) in ${delay}s"
                Start-Sleep -Seconds $delay
                continue
            }
            $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            throw "Graph $Method $Uri failed. $details"
        }
    }
}

function Get-GraphErrorDetails {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails.Message) { return $ErrorRecord.ErrorDetails.Message }
    return $ErrorRecord.Exception.Message
}

function Get-GraphContentBytes {
    param([string]$Token, [string]$Uri)
    $headers = @{ Authorization = "Bearer $Token" }
    try {
        $response = Invoke-WebRequest -Method GET -Uri $Uri -Headers $headers -ErrorAction Stop
        return $response.RawContentStream.ToArray()
    }
    catch {
        throw "Graph GET $Uri failed. $(Get-GraphErrorDetails -ErrorRecord $_)"
    }
}

function Push-FileOperationActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$Action,
        [string]$TargetName,
        [string]$TargetPath,
        [string]$TargetType = 'File',
        [string]$Outcome = 'Success',
        [string]$ErrorMessage = '',
        [hashtable]$ExtraProperties = @{}
    )

    $props = @{
        Service = 'SharePoint Online'
        Workload = 'SPO'
        Action = $Action
        TargetName = $TargetName
        TargetType = $TargetType
        TargetPath = $TargetPath
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
        ActivityExplorerComplexity = 'Low'
        ActivityExplorerTarget = $true
    }
    foreach ($key in $ExtraProperties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $props[$key] = $ExtraProperties[$key] }
    }

    Push-AgentActivity -AgentUPN $AgentUPN -AgentName $AgentName -Department $Department `
        -ActivityType 'activity_explorer' -Detail "$Action | $TargetPath" `
        -Properties $props
}

function Invoke-ActivityExplorerFileSignals {
    param(
        [string]$Token,
        [string]$SiteId,
        $Agent,
        [string]$AgentUPN,
        $SourceItem,
        [string]$SourceFileName,
        [string]$SourcePath,
        [string]$Folder,
        [byte[]]$SourceBytes,
        [string]$TimeStr
    )

    if (-not $SourceItem -or -not $SourceItem.id -or -not $SiteId) { return }
    if (-not (Test-ServiceRequested -Aliases @('spo','sharepoint','sharepoint online','files','fileops','activity explorer','activityexplorer','audit'))) { return }

    $sourceItemId = $SourceItem.id
    $targetType = if ($SourceFileName -like '*.png') { 'Image' } else { 'File' }

    try {
        Invoke-Graph -Token $Token -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$sourceItemId" | Out-Null
        Write-Output "    [$TimeStr] File read: $SourcePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRead' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRead' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    try {
        $downloadBytes = Get-GraphContentBytes -Token $Token -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$sourceItemId/content"
        Write-Output "    [$TimeStr] File downloaded: $SourcePath ($($downloadBytes.Length) bytes)"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'DownloadFile' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -ExtraProperties @{ DownloadedBytes = $downloadBytes.Length }
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'DownloadFile' -TargetName $SourceFileName -TargetPath $SourcePath -TargetType $targetType `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $suffix = Get-Random -Minimum 100 -Maximum 999
    $noteName = "ActivityExplorer_Note_${stamp}_${suffix}.txt"
    $notePath = "$Folder/$noteName"
    $noteText = @"
Activity Explorer simulation note
Actor: $($Agent.Name) <$AgentUPN>
Source file: $SourcePath
Purpose: Generate low-complexity SharePoint upload/text activity for Purview Activity Explorer validation.
Sensitive sample: SSN 384-29-5187; routing 021000021; employee id EMP-$(Get-Random -Minimum 10000 -Maximum 99999)
"@

    try {
        $noteBytes = [System.Text.Encoding]::UTF8.GetBytes($noteText)
        $noteItem = Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$notePath`:/content" `
            -Body $noteBytes -ContentType 'text/plain'
        Write-Output "    [$TimeStr] Upload text: $notePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'UploadText' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileCreated' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        $script:totalFileOps += 2

        $modifiedText = $noteText + "`nReview status: modified during simulated daily work."
        $modifiedBytes = [System.Text.Encoding]::UTF8.GetBytes($modifiedText)
        Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($noteItem.id)/content" `
            -Body $modifiedBytes -ContentType 'text/plain' | Out-Null
        Write-Output "    [$TimeStr] File modified: $notePath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileModified' -TargetName $noteName -TargetPath $notePath -TargetType 'Text'
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'UploadText' -TargetName $noteName -TargetPath $notePath -TargetType 'Text' `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }

    $scratchName = "ActivityExplorer_WorkingCopy_${stamp}_$(Get-Random -Minimum 100 -Maximum 999).txt"
    $renamedScratchName = "ActivityExplorer_Renamed_${stamp}_$(Get-Random -Minimum 100 -Maximum 999).txt"
    $scratchPath = "$Folder/$scratchName"
    $renamedScratchPath = "$Folder/$renamedScratchName"
    $scratchContent = if ($SourceBytes -and $SourceBytes.Length -gt 0) {
        $SourceBytes
    } else {
        [System.Text.Encoding]::UTF8.GetBytes("Working copy generated by $($Agent.Name) for Activity Explorer simulation.")
    }

    try {
        $scratchItem = Invoke-Graph -Token $Token -Method PUT `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$scratchPath`:/content" `
            -Body $scratchContent -ContentType 'application/octet-stream'
        Write-Output "    [$TimeStr] File created: $scratchPath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileCreated' -TargetName $scratchName -TargetPath $scratchPath
        $script:totalFileOps++

        $renamedItem = Invoke-Graph -Token $Token -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($scratchItem.id)" `
            -Body @{ name = $renamedScratchName }
        Write-Output "    [$TimeStr] File renamed: $scratchName -> $renamedScratchName"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileRenamed' -TargetName $renamedScratchName -TargetPath $renamedScratchPath `
            -ExtraProperties @{ PreviousTargetName = $scratchName; PreviousTargetPath = $scratchPath }
        $script:totalFileOps++

        Invoke-Graph -Token $Token -Method DELETE `
            -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($renamedItem.id)" | Out-Null
        Write-Output "    [$TimeStr] File deleted: $renamedScratchPath"
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileDeleted' -TargetName $renamedScratchName -TargetPath $renamedScratchPath
        $script:totalFileOps++
    }
    catch {
        Push-FileOperationActivity -AgentUPN $AgentUPN -AgentName $Agent.Name -Department $Agent.Dept `
            -Action 'FileLifecycleSimulation' -TargetName $scratchName -TargetPath $scratchPath `
            -Outcome 'Failed' -ErrorMessage (Get-GraphErrorDetails -ErrorRecord $_)
    }
}

# =============================================================================
# AZURE DATA EXPLORER - push agent activity directly (workaround: OAI diagnostics
# don't include the 'user' field from the request body)
# =============================================================================
$script:adxIngestBaseUri = $null
$script:adxDatabase      = $null
$script:adxTable         = $null
$script:adxMapping       = $null
$script:adxToken         = $null

function Get-AdxAppToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://kusto.kusto.windows.net/.default'
        grant_type    = 'client_credentials'
    }
    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body -ErrorAction Stop
    return $tokenResponse.access_token
}

function Initialize-AdxIngestion {
    if (-not $adxConfig -or $adxConfig.enabled -ne $true) {
        Write-Warning "  [ADX] ADX telemetry is not configured. Agent telemetry will not be ingested."
        return
    }

    try {
        $adxKeyVaultName = if ($adxConfig.keyVaultName) { [string]$adxConfig.keyVaultName } else { $keyVaultName }
        $adxSecretName = if ($adxConfig.clientSecretName) { [string]$adxConfig.clientSecretName } else { [string]$clientSecretName }
        if ([string]::IsNullOrWhiteSpace($adxSecretName)) { $adxSecretName = 'agent-client-secret' }
        $adxSecret = Get-KeyVaultSecretValue -VaultName $adxKeyVaultName -SecretName $adxSecretName
        if ([string]::IsNullOrWhiteSpace($adxSecret)) {
            throw "ADX client secret '$adxSecretName' is empty or missing in Key Vault '$adxKeyVaultName'."
        }

        # Streaming ingest REST uses the cluster URI, not the queued ingest URI.
        $script:adxIngestBaseUri = ConvertTo-AAPlainString $adxConfig.queryBaseUri
        if ([string]::IsNullOrWhiteSpace($script:adxIngestBaseUri)) {
            $script:adxIngestBaseUri = ConvertTo-AAPlainString $adxConfig.ingestBaseUri
        }
        $script:adxDatabase = ConvertTo-AAPlainString $adxConfig.databaseName
        $script:adxTable = ConvertTo-AAPlainString $adxConfig.tableName
        $script:adxMapping = ConvertTo-AAPlainString $adxConfig.mappingName
        $script:adxToken = Get-AdxAppToken -TenantId $adxConfig.tenantId -ClientId $adxConfig.clientId -ClientSecret $adxSecret
        Write-Output "  [ADX] Ingestion initialized for $($script:adxDatabase).$($script:adxTable)"
    }
    catch {
        Write-Warning "  [ADX] Failed to initialize ingestion: $($_.Exception.Message)"
    }
}

function Push-AgentActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$ActivityType,   # file, email, teams, chat, fabric, copilot, thread, external_ai
        [string]$Detail,
        [int]$TokensIn = 0,
        [int]$TokensOut = 0,
        [string]$PromptContent = '',
        [string]$ResponseContent = '',
        [hashtable]$Properties = @{}
    )
    if (-not $script:adxToken -or -not $script:adxIngestBaseUri) { return }

    # Keep payloads compact and bounded for near-real-time ingestion.
    if ($PromptContent.Length -gt 30000) { $PromptContent = $PromptContent.Substring(0, 30000) + '...[truncated]' }
    if ($ResponseContent.Length -gt 30000) { $ResponseContent = $ResponseContent.Substring(0, 30000) + '...[truncated]' }

    $event = @{
        AgentUPN        = $AgentUPN
        AgentName       = $AgentName
        Department      = $Department
        ActivityType    = $ActivityType
        Detail          = $Detail
        PromptTokens    = $TokensIn
        ResponseTokens  = $TokensOut
        PromptContent   = $PromptContent
        ResponseContent = $ResponseContent
        ActorUPN        = $AgentUPN
        ActorName       = $AgentName
        ActorDepartment = $Department
    }
    foreach ($key in $Properties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
            $event[$key] = $Properties[$key]
        }
    }

    $record = @{
        TimeGenerated = (Get-Date).ToUniversalTime().ToString('o')
        Event = $event
    } | ConvertTo-Json -Depth 10 -Compress

    $encodedDb = [System.Uri]::EscapeDataString($script:adxDatabase)
    $encodedTable = [System.Uri]::EscapeDataString($script:adxTable)
    $encodedMapping = [System.Uri]::EscapeDataString($script:adxMapping)
    $ingestUri = "$($script:adxIngestBaseUri.TrimEnd('/'))/v1/rest/ingest/$encodedDb/${encodedTable}?streamFormat=json&mappingName=$encodedMapping"

    try {
        Invoke-RestMethod -Method POST `
            -Uri $ingestUri `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $($script:adxToken)" } `
            -Body $record | Out-Null
    }
    catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "  [ADX] Failed to ingest activity '$ActivityType' for '$AgentName': $details"
    }
}

# =============================================================================
# AZURE OPENAI - content generation via Managed Identity
# =============================================================================
function Get-OaiToken {
    # Azure Automation sandboxes don't support IMDS; use Az module token
    $azToken = (Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com/').Token
    $azToken
}

function Invoke-OAI {
    param([string]$OaiToken, [string]$SystemPrompt, [string]$UserPrompt, [int]$MaxTokens = 1500, [string]$UserId = '')

    $body = @{
        messages = @(
            @{ role = 'system'; content = (ConvertTo-AASafeText -Text $SystemPrompt -MaxLength 12000) }
            @{ role = 'user';   content = (ConvertTo-AASafeText -Text $UserPrompt -MaxLength 20000) }
        )
        max_completion_tokens = $MaxTokens
        temperature = 0.9
    }
    # Inject agent UPN as 'user' field for Azure OpenAI request attribution.
    # First-party activity telemetry is written directly to ADX.
    if ($UserId) { $body.user = $UserId }

    $jsonBody = ConvertTo-AAJsonBody -Value $body -Depth 8

    $uri = "${OaiEndpoint}openai/deployments/${OaiDeployment}/chat/completions?api-version=2024-02-01"

    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $OaiToken"; 'Content-Type' = 'application/json' } `
            -ContentType 'application/json' -Body $jsonBody
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure OpenAI chat completion failed. $details"
    }

    $resp.choices[0].message.content
}

function Get-FoundryToken {
    try {
        $token = (Get-AzAccessToken -ResourceUrl 'https://ai.azure.com/' -ErrorAction Stop).Token
        if ($token) { return $token }
    } catch {}
    try {
        return (Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com/' -ErrorAction Stop).Token
    } catch {
        throw "Could not acquire a bearer token for Azure AI Foundry. $($_.Exception.Message)"
    }
}

function Invoke-FoundryChatCompletion {
    param(
        [string]$Endpoint,
        [string]$DeploymentName,
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [int]$MaxTokens = 900,
        [string]$UserId = ''
    )

    $cleanEndpoint = (ConvertTo-AAPlainString $Endpoint).TrimEnd('/')
    $deployment = ConvertTo-AAPlainString $DeploymentName
    if ([string]::IsNullOrWhiteSpace($cleanEndpoint) -or [string]::IsNullOrWhiteSpace($deployment)) {
        throw "Foundry endpoint or deployment name is empty."
    }

    $uri = if ($cleanEndpoint -match '/chat/completions$') {
        $cleanEndpoint
    } elseif ($cleanEndpoint -match '/openai/v1$') {
        "$cleanEndpoint/chat/completions"
    } elseif ($cleanEndpoint -match '\.openai\.azure\.com$') {
        "$cleanEndpoint/openai/v1/chat/completions"
    } else {
        "$cleanEndpoint/models/chat/completions?api-version=2024-05-01-preview"
    }

    $body = @{
        model = $deployment
        messages = @(
            @{ role = 'system'; content = (ConvertTo-AASafeText -Text $SystemPrompt -MaxLength 12000) }
            @{ role = 'user';   content = (ConvertTo-AASafeText -Text $UserPrompt -MaxLength 20000) }
        )
        max_completion_tokens = $MaxTokens
        temperature = 0.3
    }
    if ($UserId) { $body.user = $UserId }

    $token = Get-FoundryToken
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -ContentType 'application/json' -Body (ConvertTo-AAJsonBody -Value $body -Depth 8)
        return $resp.choices[0].message.content
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure AI Foundry chat completion failed. $details"
    }
}

# =============================================================================
# PURVIEW INTEGRATION - Labels, Teams, DLP awareness, compliance
# =============================================================================
$script:labelCache    = $null
$script:teamCache     = $null
$script:lastLabelError = ''

function Get-SensitivityLabels {
    param([string]$Token)
    if ($script:labelCache) { return $script:labelCache }
    try {
        $resp = Invoke-Graph -Token $Token -Uri 'https://graph.microsoft.com/beta/me/informationProtection/policy/labels'
        $script:labelCache = $resp.value
        Write-Output "  [LABELS] Cached $($resp.value.Count) sensitivity labels"
    }
    catch {
        Write-Warning "  [LABELS] Failed to load: $($_.Exception.Message)"
        $script:labelCache = @()
    }
    $script:labelCache
}

function Get-LabelName {
    param($Label)
    if (-not $Label) { return '' }
    if ($Label.displayName) { return ([string]$Label.displayName).Trim() }
    if ($Label.name) { return ([string]$Label.name).Trim() }
    return ''
}

function Get-LabelParentName {
    param($Label)
    if (-not $Label -or -not $Label.parent) { return '' }
    if ($Label.parent.displayName) { return ([string]$Label.parent.displayName).Trim() }
    if ($Label.parent.name) { return ([string]$Label.parent.name).Trim() }
    return ''
}

function Test-LabelMatchesName {
    param($Label, [string]$TargetName)
    if (-not $Label -or [string]::IsNullOrWhiteSpace($TargetName)) { return $false }

    $target = $TargetName.Trim()
    $labelName = Get-LabelName -Label $Label
    $parentName = Get-LabelParentName -Label $Label

    if ($labelName -eq $target) { return $true }
    if ($labelName -like "*$target*") { return $true }

    if ($target -match '/') {
        $parts = @($target -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -ge 2) {
            $targetParent = $parts[0]
            $targetLeaf = $parts[-1]
            if ($labelName -eq $targetLeaf -and $parentName -eq $targetParent) { return $true }
            if ($labelName -like "*$targetLeaf*" -and $parentName -like "*$targetParent*") { return $true }
        }
    }

    return $false
}

function Resolve-LabelForFile {
    param([string]$Dept, [string]$FileType, [array]$Labels)
    $rules = $labelRules[$Dept]
    if (-not $rules) { return $null }
    $targetName = if ($rules.High -contains $FileType) { $rules.HighLabel } else { $rules.DefaultLabel }
    $match = $Labels | Where-Object { Test-LabelMatchesName -Label $_ -TargetName $targetName }
    if ($match -is [array]) { $match = $match | Select-Object -First 1 }
    $match
}

function Apply-FileLabel {
    param([string]$Token, [string]$SiteId, [string]$ItemId, [string]$LabelId, [string]$LabelName)
    if (-not $LabelId -or -not $ItemId) { return $false }
    $script:lastLabelError = ''
    $body = @{
        sensitivityLabelId = $LabelId
        assignmentMethod   = 'standard'
        justificationText  = "Classification departementale: $LabelName"
    }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/beta/sites/$SiteId/drive/items/$ItemId/assignSensitivityLabel" `
            -Body $body | Out-Null
        return $true
    }
    catch {
        $script:lastLabelError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "    [LABEL] Apply failed: $script:lastLabelError"
        return $false
    }
}

function Push-LabelActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$Action,
        [string]$TargetName,
        [string]$TargetPath,
        [string]$TargetType = 'File',
        [string]$LabelName = '',
        [string]$LabelId = '',
        [string]$PreviousLabelName = '',
        [string]$PreviousLabelId = '',
        [string]$Outcome = 'Success',
        [string]$ErrorMessage = '',
        [hashtable]$ExtraProperties = @{}
    )

    $changeType = switch ($Action) {
        'SensitivityLabelApplied' { 'applied' }
        'SensitivityLabelChanged' { 'changed' }
        'SensitivityLabelRemoved' { 'removed' }
        'SensitivityLabelApplyFailed' { 'apply_failed' }
        default { 'unknown' }
    }

    $props = @{
        Service = 'Microsoft Purview'
        Workload = 'InformationProtection'
        Action = $Action
        LabelChangeType = $changeType
        TargetName = $TargetName
        TargetType = $TargetType
        TargetPath = $TargetPath
        SensitivityLabel = $LabelName
        SensitivityLabelId = $LabelId
        PreviousSensitivityLabel = $PreviousLabelName
        PreviousSensitivityLabelId = $PreviousLabelId
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
    }
    foreach ($key in $ExtraProperties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $props[$key] = $ExtraProperties[$key] }
    }

    $detailLabel = if ($LabelName) { $LabelName } else { 'none' }
    Push-AgentActivity -AgentUPN $AgentUPN -AgentName $AgentName -Department $Department `
        -ActivityType 'sensitivity_label' -Detail "$Action | $TargetName | $detailLabel" `
        -Properties $props
}

function Get-LabelByName {
    param([array]$Labels, [string[]]$Names)
    foreach ($name in $Names) {
        $match = $Labels | Where-Object { Test-LabelMatchesName -Label $_ -TargetName $name } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

function Invoke-DevonInsiderRiskSequence {
    param($Agent, [string]$Token, [string]$UserUpn)

    if (-not $spoSiteId) {
        Write-Warning "    [IRM] AgentSpoSiteId not configured; skipping Devon IRM sequence."
        return 0
    }

    $scenarios = @(
        @{ Name='Download from Microsoft 365 location, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='Microsoft365' }
        @{ Name='Download from Microsoft 365 location, obfuscate, exfiltrate, then delete'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$true;  Source='Microsoft365' }
        @{ Name='Archive, obfuscate, then exfiltrate'; Archive=$true;  Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='Microsoft365' }
        @{ Name='Archive, obfuscate, exfiltrate, then delete'; Archive=$true;  Obfuscate=$true;  Downgrade=$false; Delete=$true;  Source='Microsoft365' }
        @{ Name='Downgrade or remove label then exfiltrate'; Archive=$false; Obfuscate=$false; Downgrade=$true;  Delete=$false; Source='Microsoft365' }
        @{ Name='Downgrade or remove label, download, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$true;  Delete=$false; Source='Microsoft365' }
        @{ Name='Downgrade or remove label, download, exfiltrate, then delete'; Archive=$false; Obfuscate=$false; Downgrade=$true;  Delete=$true;  Source='Microsoft365' }
        @{ Name='Download from unallowed domain, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='UnallowedDomain' }
    )
    $scenario = $scenarios | Get-Random
    $caseId = "IRM-DEVON-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$(Get-Random -Minimum 100 -Maximum 999)"
    $folder = 'Insider Risk Devon'
    $fileName = "${caseId}_support_exports.txt"
    $targetPath = "$folder/$fileName"
    $externalRecipient = 'devon.reyes.exfil@outlook.com'
    $eventCount = 0

    $content = @"
Case: $caseId
Actor: $($Agent.Name) <$UserUpn>
Scenario: $($scenario.Name)
Source: $($scenario.Source)

Customer escalation export
Customer: Contoso Retail Services
Contact: Morgan Lee, morgan.lee@example.com, +1 206 555 0174
Employee: Jordan Avery
social security number: 384-29-5187
bank routing number: 021000021
bank account number: 492017388201
Support case: SR-948211
Notes: Raw customer support evidence copied for external AI triage and off-platform review.
"@
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $labels = Get-SensitivityLabels -Token $Token
    $highLabel = Get-LabelByName -Labels $labels -Names @('Highly Confidential/All Employees','Confidential/All Employees','Confidential')
    $lowLabel = Get-LabelByName -Labels $labels -Names @('General/All Employees','General')

    try {
        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
        $uploadResult = Invoke-Graph -Token $Token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'text/plain'
        Write-Output "    [IRM] Uploaded source evidence: $targetPath"

        $labelApplied = ''
        if ($highLabel -and $uploadResult.id) {
            $highLabelName = Get-LabelName -Label $highLabel
            if (Apply-FileLabel -Token $Token -SiteId $spoSiteId -ItemId $uploadResult.id -LabelId $highLabel.id -LabelName $highLabelName) {
                $labelApplied = $highLabelName
                Write-Output "    [IRM] High label applied: $labelApplied"
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelApplied' -TargetName $fileName -TargetPath $targetPath `
                    -LabelName $highLabelName -LabelId $highLabel.id `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Sensitive file staged' }
                $eventCount++
            } else {
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                    -LabelName $highLabelName -LabelId $highLabel.id -Outcome 'Failed' -ErrorMessage $script:lastLabelError `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Sensitive file staged' }
                $eventCount++
            }
        }

        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Created sensitive source file" `
            -PromptContent $scenario.Name -ResponseContent $content `
            -Properties @{
                Service = 'SharePoint Online'
                Action = 'CreatedSensitiveFile'
                Workload = 'SharePoint'
                TargetName = $fileName
                TargetType = 'File'
                TargetPath = $targetPath
                SensitivityLabel = $labelApplied
                IRMScenario = $scenario.Name
                IRMIndicator = 'Sensitive file staged'
                Outcome = 'Success'
            }
        $eventCount++

        $downloaded = Invoke-Graph -Token $Token -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/items/$($uploadResult.id)/content" -ContentType 'text/plain'
        $downloadedText = if ($downloaded) { [string]$downloaded } else { $content }
        Write-Output "    [IRM] Downloaded from Microsoft 365 location: $fileName"
        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Download from Microsoft 365 location" `
            -PromptContent $scenario.Name -ResponseContent $downloadedText `
            -Properties @{
                Service = 'SharePoint Online'
                Action = 'DownloadedFromM365'
                Workload = 'SharePoint'
                TargetName = $fileName
                TargetType = 'File'
                TargetPath = $targetPath
                IRMScenario = $scenario.Name
                IRMIndicator = 'Download from Microsoft 365 location'
                Outcome = 'Success'
            }
        $eventCount++

        if ($scenario.Downgrade -and $lowLabel -and $uploadResult.id) {
            $lowLabelName = Get-LabelName -Label $lowLabel
            if (Apply-FileLabel -Token $Token -SiteId $spoSiteId -ItemId $uploadResult.id -LabelId $lowLabel.id -LabelName $lowLabelName) {
                Write-Output "    [IRM] Label downgraded: $labelApplied -> $lowLabelName"
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelChanged' -TargetName $fileName -TargetPath $targetPath `
                    -PreviousLabelName $labelApplied -PreviousLabelId $highLabel.id `
                    -LabelName $lowLabelName -LabelId $lowLabel.id `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Downgrade or remove label' }
                $eventCount++
                Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Downgrade or remove label" `
                    -Properties @{
                        Service = 'Microsoft Purview'
                        Action = 'SensitivityLabelDowngraded'
                        Workload = 'InformationProtection'
                        TargetName = $fileName
                        TargetType = 'File'
                        TargetPath = $targetPath
                        PreviousSensitivityLabel = $labelApplied
                        SensitivityLabel = $lowLabelName
                        IRMScenario = $scenario.Name
                        IRMIndicator = 'Downgrade or remove label'
                        Outcome = 'Success'
                    }
                $eventCount++
            }
        }

        $activeItemId = $uploadResult.id
        $activeName = $fileName
        $activePath = $targetPath
        $activeBytes = $bytes

        if ($scenario.Archive) {
            $archiveName = "${caseId}_archive.zip"
            $archivePath = "$folder/$archiveName"
            $archiveText = "PK-LAB-ARCHIVE`nOriginal=$fileName`n`n$downloadedText"
            $activeBytes = [System.Text.Encoding]::UTF8.GetBytes($archiveText)
            $archiveResult = Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${archiveName}:/content" `
                -Body $activeBytes -ContentType 'application/zip'
            $activeItemId = $archiveResult.id
            $activeName = $archiveName
            $activePath = $archivePath
            Write-Output "    [IRM] Archive created: $archivePath"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Archive created" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'ArchiveCreated'
                    Workload = 'SharePoint'
                    TargetName = $archiveName
                    TargetType = 'Archive'
                    TargetPath = $archivePath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Archive then exfiltrate'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        if ($scenario.Obfuscate) {
            $obfuscatedName = "${caseId}_payload.dat"
            $obfuscatedPath = "$folder/$obfuscatedName"
            $encoded = [Convert]::ToBase64String($activeBytes)
            $encodedChars = $encoded.ToCharArray()
            [array]::Reverse($encodedChars)
            $obfuscatedText = -join $encodedChars
            $activeBytes = [System.Text.Encoding]::UTF8.GetBytes($obfuscatedText)
            $obfuscatedResult = Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${obfuscatedName}:/content" `
                -Body $activeBytes -ContentType 'application/octet-stream'
            $activeItemId = $obfuscatedResult.id
            $activeName = $obfuscatedName
            $activePath = $obfuscatedPath
            Write-Output "    [IRM] Obfuscated payload created: $obfuscatedPath"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Obfuscation" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'Obfuscated'
                    Workload = 'SharePoint'
                    TargetName = $obfuscatedName
                    TargetType = 'ObfuscatedPayload'
                    TargetPath = $obfuscatedPath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Obfuscate'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        $mailBody = @{
            message = @{
                subject = "$caseId - support export review"
                body = @{ contentType = 'Text'; content = "External review package for $caseId. Scenario: $($scenario.Name)." }
                toRecipients = @(@{ emailAddress = @{ address = $externalRecipient } })
                attachments = @(
                    @{
                        '@odata.type' = '#microsoft.graph.fileAttachment'
                        name = $activeName
                        contentType = 'application/octet-stream'
                        contentBytes = [Convert]::ToBase64String($activeBytes)
                    }
                )
            }
            saveToSentItems = $true
        }
        Invoke-Graph -Token $Token -Method POST -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $mailBody | Out-Null
        Write-Output "    [IRM] Exfiltrated to external recipient: $externalRecipient"
        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Exfiltrate to external email" `
            -Properties @{
                Service = 'Exchange Online'
                Action = 'ExfiltratedExternalEmail'
                Workload = 'Exchange'
                TargetName = $activeName
                TargetType = 'EmailAttachment'
                TargetPath = $activePath
                RecipientUPN = $externalRecipient
                IRMScenario = $scenario.Name
                IRMIndicator = 'Exfiltrate'
                Outcome = 'Success'
            }
        $eventCount++

        if ($scenario.Delete -and $activeItemId) {
            Invoke-Graph -Token $Token -Method DELETE -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/items/$activeItemId" | Out-Null
            Write-Output "    [IRM] Deleted post-exfiltration artifact: $activeName"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Delete after exfiltration" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'DeletedAfterExfiltration'
                    Workload = 'SharePoint'
                    TargetName = $activeName
                    TargetType = 'File'
                    TargetPath = $activePath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Delete'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        Write-Output "    [IRM] Devon scenario completed: $($scenario.Name) ($eventCount events)"
        return $eventCount
    } catch {
        Write-Warning "    [IRM] Devon scenario failed: $($_.Exception.Message)"
        return $eventCount
    }
}

function Get-TeamAndChannels {
    param([string]$Token)
    if ($script:teamCache) { return $script:teamCache }
    if (-not $teamsGroupId) {
        Write-Warning "  [TEAMS] AgentTeamsGroupId not configured -- skipping Teams"
        return $null
    }
    # Primary: use pre-resolved channel mapping from AA variable (no Graph call needed)
    if ($teamsChannelsJson) {
        try {
            $chMap = $teamsChannelsJson | ConvertFrom-Json
            $script:teamCache = @{ TeamId = $teamsGroupId; Channels = @{} }
            foreach ($prop in $chMap.PSObject.Properties) {
                $script:teamCache.Channels[$prop.Name] = $prop.Value
            }
            Write-Output "  [TEAMS] Loaded $($script:teamCache.Channels.Count) channels from config"
            return $script:teamCache
        } catch {
            Write-Warning "  [TEAMS] Failed to parse AgentTeamsChannels: $($_.Exception.Message)"
        }
    }
    # Fallback: resolve via Graph API (requires Channel.ReadBasic.All)
    try {
        $channels = Invoke-Graph -Token $Token -Uri "https://graph.microsoft.com/v1.0/teams/$teamsGroupId/channels"
        $script:teamCache = @{ TeamId = $teamsGroupId; Channels = @{} }
        foreach ($ch in $channels.value) {
            $script:teamCache.Channels[$ch.displayName] = $ch.id
        }
        Write-Output "  [TEAMS] Resolved team $teamsGroupId with $($channels.value.Count) channels"
    }
    catch {
        Write-Warning "  [TEAMS] Resolve failed: $($_.Exception.Message)"
        return $null
    }
    $script:teamCache
}

function Post-TeamsActivity {
    param([string]$Token, [string]$Dept, [string]$HtmlContent)
    $teamInfo = Get-TeamAndChannels -Token $Token
    if (-not $teamInfo) { return }
    $channelId = $teamInfo.Channels[$Dept]
    if (-not $channelId) { $channelId = $teamInfo.Channels['General'] }
    if (-not $channelId) { return }
    $msg = @{ body = @{ contentType = 'html'; content = $HtmlContent } }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/teams/$($teamInfo.TeamId)/channels/$channelId/messages" `
            -Body $msg | Out-Null
    }
    catch {
        # Best effort -- Teams posting is optional. 403 is common on MCAPS tenants
        # where ChannelMessage.Send is restricted by CA policies on ROPC tokens.
    }
}

function Get-CollaborationTargetForAgent {
    param([string]$Sam)
    if (-not $collaborationSites) { return $null }
    foreach ($prop in $collaborationSites.PSObject.Properties) {
        $site = $prop.Value
        if (@($site.Members) -contains $Sam) { return $site }
    }
    $null
}

function Get-CollaborationChannelId {
    param($ChannelMap, [array]$PreferredNames)
    if (-not $ChannelMap) { return $null }
    foreach ($name in $PreferredNames) {
        $prop = $ChannelMap.PSObject.Properties[$name]
        if ($prop -and $prop.Value) { return $prop.Value }
    }
    $first = $ChannelMap.PSObject.Properties | Select-Object -First 1
    if ($first) { return $first.Value }
    $null
}

function Post-CollaborationActivity {
    param($Target, [string]$Token, [string]$HtmlContent)
    if (-not $Target -or -not $Target.TeamId -or -not $Target.Channels) { return }
    $channelId = Get-CollaborationChannelId -ChannelMap $Target.Channels -PreferredNames @('Shadow AI','Leak Investigations','AI Governance','General')
    if (-not $channelId) { return }
    $msg = @{ body = @{ contentType = 'html'; content = $HtmlContent } }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/teams/$($Target.TeamId)/channels/$channelId/messages" `
            -Body $msg | Out-Null
    } catch {}
}

function Invoke-ExternalAiSimulation {
    param($Agent, [string]$Token, [string]$OaiToken, [string]$UserUpn)
    if ($externalAiServices.Count -eq 0) { return 0 }

    $runtimeAgents = if ($externalAiRuntime -and $externalAiRuntime.agentSams) { @($externalAiRuntime.agentSams) } else { @() }
    $useRealFoundry = $externalAiRuntime -and
        $externalAiRuntime.enabled -eq $true -and
        $externalAiRuntime.mode -eq 'foundry' -and
        ($runtimeAgents -contains $Agent.Sam) -and
        -not [string]::IsNullOrWhiteSpace([string]$externalAiRuntime.endpoint) -and
        -not [string]::IsNullOrWhiteSpace([string]$externalAiRuntime.deploymentName)

    $service = $null
    if ($useRealFoundry -and $externalAiRuntime.serviceName) {
        $service = $externalAiServices | Where-Object { $_.name -eq $externalAiRuntime.serviceName } | Select-Object -First 1
    }
    if (-not $service -and $requestedServices.Count -gt 0) {
        foreach ($requested in $requestedServices) {
            $service = $externalAiServices | Where-Object {
                "$($_.name) $($_.provider) $($_.modelFamily)".ToLowerInvariant() -match [regex]::Escape($requested)
            } | Select-Object -First 1
            if ($service) { break }
        }
    }
    if (-not $service) { $service = $externalAiServices | Get-Random }
    $target = Get-CollaborationTargetForAgent -Sam $Agent.Sam
    $caseId = "DSPM-AI-$((Get-Date).ToString('yyyyMMdd'))-$(Get-Random -Minimum 1000 -Maximum 9999)"
    $prompt = @"
Controlled non-Copilot AI test inside Azure.
Act as $($service.name) ($($service.provider) / $($service.modelFamily)).

User: $($Agent.Name) <$UserUpn>
Case: $caseId
Risk profile: $($service.riskProfile)

Task: analyze whether the following evidence can be pasted into a non-Copilot AI assistant.
Include a concise response, risk classification, and remediation advice.

Evidence sample:
- employee record with social security number 384-22-9147
- direct deposit routing number 021000021 and account number 7788123401
- customer contact jean.dupont@corplab.fr, phone +1 415 555 0198
- source: Teams export and SharePoint incident notes
"@

    $runtimeMode = if ($useRealFoundry) { 'RealFoundry' } else { 'Simulated' }
    $runtimeError = ''
    try {
        if ($useRealFoundry) {
            $response = Invoke-FoundryChatCompletion `
                -Endpoint $externalAiRuntime.endpoint `
                -DeploymentName $externalAiRuntime.deploymentName `
                -SystemPrompt ($Agent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $prompt -MaxTokens 900 -UserId $UserUpn
        } else {
            $response = Invoke-OAI -OaiToken $OaiToken `
                -SystemPrompt ($Agent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $prompt -MaxTokens 900 -UserId $UserUpn
        }
    } catch {
        $runtimeError = $_.Exception.Message
        $runtimeMode = if ($useRealFoundry) { 'FoundryFallbackSimulation' } else { 'SimulatedFallback' }
        if ($useRealFoundry -and $externalAiRuntime.fallbackToSimulation -ne $true) { throw }
        $response = "External AI simulation fallback for $caseId. Risk: High. Sensitive data types detected: SSN, bank routing/account number, email, phone. Recommendation: block raw prompt, redact identifiers, retain audit evidence in DSPM review."
    }

    $detail = "$($service.name) | $caseId | $runtimeMode | $($service.riskProfile)"
    Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
        -ActivityType 'external_ai' -Detail $detail `
        -PromptContent $prompt -ResponseContent $response `
        -Properties @{
            Service = $service.name
            Provider = $service.provider
            ModelFamily = $service.modelFamily
            Action = 'Prompted'
            Workload = 'ExternalAI'
            TargetName = $caseId
            TargetType = 'AIInteraction'
            TargetPath = if ($target) { $target.TeamName } else { 'Unmapped collaboration team' }
            RiskProfile = $service.riskProfile
            RuntimeMode = $runtimeMode
            FoundryEndpoint = if ($useRealFoundry) { $externalAiRuntime.endpoint } else { '' }
            FoundryDeployment = if ($useRealFoundry) { $externalAiRuntime.deploymentName } else { '' }
            RuntimeError = $runtimeError
            ContentDepartment = $Agent.ContentDept
            Outcome = 'Success'
        }

    if ($target -and $target.SiteId) {
        $fileName = "ShadowAI_$($Agent.Sam)_$caseId.md"
        $artifact = @"
# $caseId

User: $($Agent.Name) <$UserUpn>
Service: $($service.name)
Provider: $($service.provider)
Model family: $($service.modelFamily)
Runtime mode: $runtimeMode
Risk profile: $($service.riskProfile)
Foundry deployment: $(if ($useRealFoundry) { $externalAiRuntime.deploymentName } else { 'N/A' })

## Prompt
$prompt

## Response
$response

## DSPM Notes
Controlled non-Copilot AI interaction for data leakage monitoring. Review in Purview DSPM for AI, Teams DLP, SharePoint DLP, and ADX where ActivityType == 'external_ai'.
"@
        try {
            Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$($target.SiteId)/drive/root:/${fileName}:/content" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($artifact)) `
                -ContentType 'text/markdown' | Out-Null
            Write-Output "    [EXTERNAL-AI] Evidence uploaded: $($target.DisplayName)/$fileName"
        } catch {
            Write-Warning "    [EXTERNAL-AI] Evidence upload failed: $($_.Exception.Message)"
        }

        $html = "<b>$($Agent.Name)</b> used <b>$($service.name)</b> for <b>$caseId</b><br/><small>Runtime: $runtimeMode. Risk: $($service.riskProfile). Evidence stored in SharePoint and ADX telemetry.</small>"
        Post-CollaborationActivity -Target $target -Token $Token -HtmlContent $html
    }

    Write-Output "    [EXTERNAL-AI] $($service.name) | $caseId | $runtimeMode"
    1
}

function Get-UnlabeledFiles {
    param([string]$Token, [string]$SiteId, [string]$Folder)
    try {
        $uri = "https://graph.microsoft.com/beta/sites/$SiteId/drive/root:/${Folder}:/children?`$select=id,name,sensitivityLabel,createdDateTime&`$top=50"
        $items = Invoke-Graph -Token $Token -Uri $uri
        $unlabeled = $items.value | Where-Object { -not $_.sensitivityLabel -or -not $_.sensitivityLabel.labelId }
        $unlabeled
    }
    catch {
        Write-Warning "    [SCAN] Scan failed for ${Folder}: $($_.Exception.Message)"
        @()
    }
}

# =============================================================================
# ACTIVITY SCHEDULER - random working hour simulation
# =============================================================================
function Get-RandomWorkSchedule {
    param([int]$StartHour, [int]$EndHour, [int]$FileCount, [int]$EmailCount)

    $activities = @()

    for ($i = 0; $i -lt $FileCount; $i++) {
        $maxH = [Math]::Max($StartHour + 1, $EndHour)
        $hour   = Get-Random -Minimum $StartHour -Maximum $maxH
        $minute = Get-Random -Minimum 0 -Maximum 60
        $activities += @{ Time = ($hour * 60 + $minute); Type = 'file'; Index = $i }
    }

    for ($i = 0; $i -lt $EmailCount; $i++) {
        $eMin = [Math]::Min($StartHour + 1, $EndHour - 1)
        $eMax = [Math]::Max($eMin + 1, $EndHour)
        $emailHour = Get-Random -Minimum $eMin -Maximum $eMax
        $minute    = Get-Random -Minimum 0 -Maximum 60
        $activities += @{ Time = ($emailHour * 60 + $minute); Type = 'email'; Index = $i }
    }

    $activities | Sort-Object { $_.Time }
}

function Get-DelaySeconds {
    param([int]$CurrentTimeMin, [int]$NextTimeMin)
    $diff = ($NextTimeMin - $CurrentTimeMin) * 60
    if ($diff -lt 3) { $diff = Get-Random -Minimum 3 -Maximum 15 }
    if ($diff -gt 60) { $diff = Get-Random -Minimum 10 -Maximum 60 }
    $diff
}

# =============================================================================
# MAIN
# =============================================================================
$today = Get-Date
if (-not $bSkipWeekendCheck -and $today.DayOfWeek -in @('Saturday','Sunday')) {
    Write-Output "Weekend detected -- skipping. Use SkipWeekendCheck=True to override."
    return
}

Write-Output "=== AI Agent Daily Activity -- $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
Write-Output "Mode: $ActivityMode | Emails: $bSendEmails | OpenAI: $OaiDeployment"

# -- Connect to Azure (Managed Identity) + load secrets ----------------------
Write-Output "Connecting via Managed Identity..."
Connect-AzAccount -Identity | Out-Null
if ($subscriptionId) {
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Output "Azure context set to subscription $subscriptionId."
}
$tenantId     = Get-AutomationVariable -Name 'AgentTenantId'
$appId        = Get-AutomationVariable -Name 'AgentAppId'
$keyVaultName = Get-AutomationVariable -Name 'AgentKeyVaultName'
$clientSecretName = Get-AutomationVariable -Name 'AgentClientSecretName'
$clientSecret = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $clientSecretName
$keyVaultNameForLog = ConvertTo-AAPlainString $keyVaultName
if ([string]::IsNullOrWhiteSpace($clientSecret)) {
    Write-Warning "  [AUTH] Client secret '$clientSecretName' is empty or missing in Key Vault '$keyVaultNameForLog'. Re-run Step 5."
}
Write-Output "Key Vault credentials loaded from $keyVaultNameForLog."
Initialize-AdxIngestion

# -- Get Azure OpenAI token via Managed Identity (RBAC) ----------------------
Write-Output "Acquiring OpenAI token via Managed Identity RBAC..."
$oaiToken = Get-OaiToken
Write-Output "OpenAI token acquired (length=$($oaiToken.Length))"

# -- Filter agents if specified -----------------------------------------------
$activeAgents = $agents
if ($RunAsAgent) {
    $activeAgents = $agents | Where-Object { $_.Sam -eq $RunAsAgent }
    if (-not $activeAgents) { throw "Agent '$RunAsAgent' not found" }
}

$totalFiles  = 0
$totalEmails = 0
$script:totalFileOps = 0
$totalExternalAi = 0
$totalInsiderRisk = 0
$dayContext  = "Today is $(Get-Date -Format 'dddd d MMMM yyyy'). It is a normal workday."

# -- Determine activity mode timing ------------------------------------------
switch ($ActivityMode) {
    'morning'   { $activeAgents | ForEach-Object { $_.EndHour   = [Math]::Min($_.EndHour, 13) } }
    'afternoon' { $activeAgents | ForEach-Object { $_.StartHour = [Math]::Max($_.StartHour, 13) } }
    'burst'     { $activeAgents | ForEach-Object { $_.EndHour   = $_.StartHour + 2 } }
}

foreach ($agent in $activeAgents) {
    $upn = $agent.Upn
    Write-Output "`n========================================================"
    Write-Output "  $($agent.Name) | $($agent.Dept) | $($agent.Title)"
    Write-Output "  Working hours: $($agent.StartHour):00 - $($agent.EndHour):00"
    Write-Output "========================================================"

    # -- Authenticate as this agent (ROPC) ------------------------------------
    $agentPwdSecretName = Get-AutomationVariable -Name "AgentPwdSecret-$($agent.Sam)" -ErrorAction SilentlyContinue
    if (-not $agentPwdSecretName) { $agentPwdSecretName = $agent.SecretName }
    $agentPwd = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $agentPwdSecretName
    if ([string]::IsNullOrWhiteSpace($agentPwd)) {
        Write-Warning "  [AUTH] Password secret '$(ConvertTo-AAPlainString $agentPwdSecretName)' is empty or missing in Key Vault '$keyVaultNameForLog'. Re-run Step 1 and Step 5 with a non-empty shared password."
        continue
    }
    try {
        $token = Get-ROPCToken -Username $upn -Password $agentPwd `
            -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
        Write-Output "  [AUTH] ROPC token acquired"
    }
    catch {
        Write-Warning "  [AUTH] ROPC failed for ${upn}: $($_.Exception.Message)"
        continue
    }

    # OneLake token for Fabric workload (storage audience)
    $oneLakeToken = $null
    if ($agent.Workload -eq 'Fabric' -and $fabricEnabled) {
        try {
            $oneLakeToken = Get-OneLakeToken -Username $upn -Password $agentPwd `
                -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
            Write-Output "  [AUTH] OneLake token acquired"
        } catch {
            Write-Warning "  [AUTH] OneLake token failed: $($_.Exception.Message)"
        }
    }

    # Reset label cache per agent (each agent has a different delegated token)
    # Team cache is NOT reset -- channels are the same for all agents
    $script:labelCache = $null

    $me = Invoke-Graph -Token $token -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,displayName'
    $agentUserId = $me.id
    Write-Output "  [ID]   $($me.displayName) ($agentUserId)"

    # -- Decide today's file count + types ------------------------------------
    $fileCount  = Get-Random -Minimum $agent.FilesPerDay[0] -Maximum ($agent.FilesPerDay[1] + 1)
    $emailCount = if ($bSendEmails) { Get-Random -Minimum $agent.EmailsPerDay[0] -Maximum ($agent.EmailsPerDay[1] + 1) } else { 0 }

            $deptFiles = $fileTypes[$agent.ContentDept]
            if (-not $deptFiles) { $deptFiles = $fileTypes['Sales'] }
            $selectedFileTypes = $deptFiles | Get-Random -Count ([Math]::Min($fileCount, $deptFiles.Count))

    $workloadAliases = switch ($agent.Workload) {
        'Teams'    { @('teams','microsoft teams') }
        'Chat'     { @('chat','teams','microsoft teams') }
        'Lists'    { @('lists','microsoft lists','sharepoint','spo') }
        'Fabric'   { @('fabric','microsoft fabric','sharepoint','spo') }
        'Meetings' { @('meetings','teams','microsoft teams') }
        'ExternalAI' { @('externalai','external ai','ai','foundry','irm','insider risk','insider risk management') }
        default    { @('spo','sharepoint','sharepoint online','files') }
    }
    $workloadAliases += @('fileops','activity explorer','activityexplorer','audit')
    if (-not (Test-ServiceRequested -Aliases $workloadAliases)) {
        $selectedFileTypes = @()
    }
    if (-not (Test-ServiceRequested -Aliases @('mail','email','exchange','exchange online','outlook'))) {
        $emailCount = 0
    }

    # -- Build random schedule for the day ------------------------------------
    $schedule = Get-RandomWorkSchedule -StartHour $agent.StartHour -EndHour $agent.EndHour `
        -FileCount $selectedFileTypes.Count -EmailCount $emailCount

    Write-Output "  [PLAN] $($selectedFileTypes.Count) files + $emailCount emails across $($agent.StartHour):00-$($agent.EndHour):00"

    # -- Execute activities in schedule order ---------------------------------
    $fileIdx  = 0
    $emailIdx = 0

    for ($si = 0; $si -lt $schedule.Count; $si++) {
        $activity = $schedule[$si]
        $tH = [int][Math]::Floor($activity.Time / 60)
        $tM = [int]($activity.Time % 60)
        $timeStr = '{0:D2}:{1:D2}' -f $tH, $tM

        if ($activity.Type -eq 'file' -and $fileIdx -lt $selectedFileTypes.Count) {
            $ft   = $selectedFileTypes[$fileIdx]
            $date = Get-Date -Format 'yyyy-MM-dd'

            # -- Generate content via Azure OpenAI or image scan -----------------
            $content = $null
            $bytes   = $null
            $userPrompt = ''

            if ($ft.Ext -eq '.png') {
                # Scanned document image: generate PNG with PII text (no AI needed)
                try {
                    $bytes = New-ScanImage -Type $ft.Type -AgentName $agent.Name -Dept $agent.Dept
                    $content = "PNG scan generated locally for $($ft.Type) by $($agent.Name) in $($agent.Dept)."
                    Write-Output "    [$timeStr] Scan generated: $($ft.Type) ($($bytes.Length) bytes, .png)"
                } catch {
                    Write-Warning "    [$timeStr] Scan failed for $($ft.Type): $($_.Exception.Message)"
                    $fileIdx++; continue
                }
            } else {
                # AI-generated text content
                $fullSystemPrompt = $agent.Prompt + "`n`n" + $sitReference
                $userPrompt = "$dayContext`n`nGenerate this document: $($ft.Prompt)`n`nDocument date: $date. Use different names/numbers each time. Output ONLY the document content, no explanations."

            # Rich formats (SVG, HTML, JSON, MD) need more tokens
            $maxTok = switch ($ft.Ext) {
                '.svg'  { 4000 }
                '.html' { 3500 }
                '.json' { 3000 }
                '.md'   { 3000 }
                '.xml'  { 3000 }
                '.csv'  { 2500 }
                default { 2000 }
            }

            try {
                $content = Invoke-OAI -OaiToken $oaiToken -SystemPrompt $fullSystemPrompt -UserPrompt $userPrompt -MaxTokens $maxTok -UserId $upn
                Write-Output "    [$timeStr] AI generated: $($ft.Type) ($($content.Length) chars, $($ft.Ext))"
            }
            catch {
                Write-Warning "    [$timeStr] OAI failed for $($ft.Type): $($_.Exception.Message)"
                $content = "$($ft.Type) - $date - Generated by $($agent.Name)`nsocial security number: $(Get-Random -Min 100 -Max 899)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000 -Max 9999)`nrouting number: $(Get-Random -Min 100000000 -Max 999999999)`naccount number: $(Get-Random -Min 1000000000 -Max 9999999999)"
            }
            } # end else (AI content)

            # -- Upload to SharePoint or execute workload-specific action ----
            $fileName  = "$($ft.Type)_${date}_$(Get-Random -Min 100 -Max 999)$($ft.Ext)"
            $folder    = $agent.Dept
            $workload  = if ($agent.Workload) { $agent.Workload } else { 'SPO' }
            $service = switch ($workload) {
                'Teams'    { 'Microsoft Teams' }
                'Chat'     { 'Microsoft Teams Chat' }
                'Lists'    { 'Microsoft Lists' }
                'Fabric'   { 'Microsoft Fabric' }
                'Meetings' { 'Microsoft Teams' }
                default    { 'SharePoint Online' }
            }
            $action = switch ($workload) {
                'Teams'    { 'Posted' }
                'Chat'     { 'SentChatMessage' }
                'Lists'    { 'UploadedListData' }
                'Fabric'   { 'UploadedDataset' }
                'Meetings' { 'UploadedMeetingNotes' }
                default    { 'Uploaded' }
            }
            $targetType = if ($ft.Ext -eq '.png') { 'Image' } else { 'File' }
            $targetPath = "$folder/$fileName"
            $recipientName = ''
            $recipientUPN = ''
            if (-not $bytes) {
                if ([string]::IsNullOrWhiteSpace($content)) {
                    $content = "$($ft.Type) - $date - Generated by $($agent.Name)"
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            }
            $labelFriendlyMode = Test-ServiceRequested -Aliases @('fileops','activity explorer','activityexplorer','audit','labels','sensitivity labels','purview')
            if ($labelFriendlyMode -and -not (Test-AASensitivityLabelSupportedExtension -Extension $ft.Ext)) {
                try {
                    $converted = ConvertTo-AALabelFriendlyFile -Type $ft.Type -Extension $ft.Ext -Content $content -Bytes $bytes
                    if ($converted.Converted) {
                        $oldExt = $ft.Ext
                        $ft.Ext = $converted.Ext
                        $bytes = $converted.Bytes
                        $content = $converted.Content
                        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($fileName) + $ft.Ext
                        $targetType = 'File'
                        $targetPath = "$folder/$fileName"
                        Write-Output "    [$timeStr] Converted $oldExt to $($ft.Ext) for Purview label/Activity Explorer support: $fileName"
                    }
                }
                catch {
                    Write-Warning "    [$timeStr] Supported-format conversion failed for ${fileName}: $($_.Exception.Message)"
                }
            }

            try {
                switch ($workload) {
                    'Teams' {
                        # Post content as a Teams channel message (Julien - HR, Olivier - Sales)
                        $htmlContent = "<h3>$($ft.Type) - $date</h3><pre>$([System.Net.WebUtility]::HtmlEncode($content.Substring(0, [math]::Min($content.Length, 2000))))</pre>"
                        Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $htmlContent
                        Write-Output "    [$timeStr] Teams post: $($ft.Type) in /$($agent.Dept)"
                        $totalFiles++
                    }
                    'Chat' {
                        # Send as Teams 1:1 chat message to a random colleague (Karim - Legal)
                        $colleagues = $agents | Where-Object { $_.Sam -ne $agent.Sam -and $_.Dept -eq $agent.Dept }
                        if (-not $colleagues) { $colleagues = $agents | Where-Object { $_.Sam -ne $agent.Sam } }
                        $target = $colleagues | Get-Random
                        $recipientName = $target.Name
                        $recipientUPN = "$($target.Sam)@$domain"
                        $targetId = Invoke-Graph -Token $token -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($target.Sam)@$domain" | Select-Object -ExpandProperty id
                        $chatBody = @{
                            chatType = 'oneOnOne'
                            members = @(
                                @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($agentUserId)')"; roles=@('owner') }
                                @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$targetId')"; roles=@('owner') }
                            )
                        } | ConvertTo-Json -Depth 4
                        $chat = Invoke-Graph -Token $token -Method POST -Uri "https://graph.microsoft.com/v1.0/chats" -Body ([System.Text.Encoding]::UTF8.GetBytes($chatBody)) -ContentType 'application/json'
                        if ($chat.id) {
                            $msgBody = @{ body = @{ contentType = 'text'; content = $content.Substring(0, [math]::Min($content.Length, 4000)) } } | ConvertTo-Json -Depth 3
                            Invoke-Graph -Token $token -Method POST -Uri "https://graph.microsoft.com/v1.0/chats/$($chat.id)/messages" -Body ([System.Text.Encoding]::UTF8.GetBytes($msgBody)) -ContentType 'application/json' | Out-Null
                            Write-Output "    [$timeStr] Teams chat: $($ft.Type) -> $($target.Name)"
                        }
                        $totalFiles++
                    }
                    'Lists' {
                        # Upload as structured CSV to SharePoint (Claire - Finance)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] SPO list data: $folder/$fileName"
                        $totalFiles++
                    }
                    'Fabric' {
                        # Upload contextualized data files to OneLake Lakehouse + SharePoint
                        # Organized by format: datasets/, schemas/, reports/, dashboards/, diagrams/
                        $subFolder = switch -Wildcard ($ft.Ext) {
                            '.csv'  { 'datasets' }
                            '.json' { 'schemas' }
                            '.md'   { 'reports' }
                            '.html' { 'dashboards' }
                            '.svg'  { 'diagrams' }
                            '.xml'  { 'integrations' }
                            '.txt'  { 'logs' }
                            default { 'misc' }
                        }
                        $fabricFolder = "$folder/$subFolder"
                        $targetPath = "$fabricFolder/$fileName"
                        if (-not $bytes) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($content) }

                        # Primary: OneLake Lakehouse (if enabled + token available)
                        if ($oneLakeToken -and $fabricWorkspaceId -and $fabricLakehouseId) {
                            try {
                                Write-OneLake -Token $oneLakeToken -WorkspaceId $fabricWorkspaceId `
                                    -LakehouseId $fabricLakehouseId -Path "$fabricFolder/$fileName" -Content $bytes
                                Write-Output "    [$timeStr] OneLake ($subFolder): $fabricFolder/$fileName"
                            } catch {
                                Write-Warning "    [$timeStr] OneLake upload failed: $($_.Exception.Message)"
                            }
                        }

                        # Secondary: SharePoint (always, for DLP/audit/auto-labeling coverage)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$fabricFolder/${fileName}:/content"
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] SPO ($subFolder): $fabricFolder/$fileName"
                        $totalFiles++
                    }
                    'Meetings' {
                        # Upload meeting notes to SharePoint + post summary in Teams (Olivier - Sales)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        if (-not $bytes) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($content) }
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] Meeting notes: $folder/$fileName"
                        # Also post a summary in Teams
                        $summary = "<b>Meeting notes</b> - $($ft.Type) ($date)<br/><small>By $($agent.Name) ($($agent.Title))</small>"
                        Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $summary
                        $totalFiles++
                    }
                    default {
                        # Default SPO file upload (Wave 1 agents)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] Uploaded: $folder/$fileName"
                        $totalFiles++
                    }
                }

                # -- Apply sensitivity label based on dept + file type --------
                $labels = Get-SensitivityLabels -Token $token
                $targetLabel = Resolve-LabelForFile -Dept $agent.ContentDept -FileType $ft.Type -Labels $labels
                $labelApplied = ''
                if ($targetLabel -and $uploadResult.id -and (Test-AASensitivityLabelSupportedExtension -Extension $ft.Ext)) {
                    $targetLabelName = Get-LabelName -Label $targetLabel
                    $ok = Apply-FileLabel -Token $token -SiteId $spoSiteId `
                        -ItemId $uploadResult.id -LabelId $targetLabel.id -LabelName $targetLabelName
                    if ($ok) {
                        $labelApplied = $targetLabelName
                        Write-Output "    [$timeStr] Label: $labelApplied"
                        Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                            -Action 'SensitivityLabelApplied' -TargetName $fileName -TargetPath $targetPath `
                            -LabelName $targetLabelName -LabelId $targetLabel.id `
                            -ExtraProperties @{
                                SourceActivity = 'FileUpload'
                                SourceWorkload = $workload
                                FileType = $ft.Type
                                FileExtension = $ft.Ext
                                Folder = $folder
                                ContentDepartment = $agent.ContentDept
                            }
                    } else {
                        Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                            -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                            -LabelName $targetLabelName -LabelId $targetLabel.id `
                            -Outcome 'Failed' -ErrorMessage $script:lastLabelError `
                            -ExtraProperties @{
                                SourceActivity = 'FileUpload'
                                SourceWorkload = $workload
                                FileType = $ft.Type
                                FileExtension = $ft.Ext
                                Folder = $folder
                                ContentDepartment = $agent.ContentDept
                            }
                    }
                }
                elseif ($targetLabel -and $uploadResult.id) {
                    $targetLabelName = Get-LabelName -Label $targetLabel
                    Write-Warning "    [LABEL] Skipped unsupported file type $($ft.Ext) for $fileName"
                    Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                        -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                        -LabelName $targetLabelName -LabelId $targetLabel.id `
                        -Outcome 'Skipped' -ErrorMessage "Unsupported file type $($ft.Ext) for Graph assignSensitivityLabel." `
                        -ExtraProperties @{
                            SourceActivity = 'FileUpload'
                            SourceWorkload = $workload
                            FileType = $ft.Type
                            FileExtension = $ft.Ext
                            Folder = $folder
                            ContentDepartment = $agent.ContentDept
                        }
                }

                # -- Log enriched activity to ADX ------------------------------
                $activityContent = if ([string]::IsNullOrWhiteSpace($content)) { "Binary file $fileName ($($bytes.Length) bytes)" } else { $content }
                Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                    -ActivityType $workload -Detail "$fileName ($($activityContent.Length) chars)" `
                    -TokensIn ([Math]::Round($activityContent.Length / 4)) -TokensOut ([Math]::Round($activityContent.Length / 4)) `
                    -PromptContent $userPrompt -ResponseContent $activityContent `
                    -Properties @{
                        Service = $service
                        Action = $action
                        Workload = $workload
                        TargetName = $fileName
                        TargetType = $targetType
                        TargetPath = $targetPath
                        FileType = $ft.Type
                        FileExtension = $ft.Ext
                        Folder = $folder
                        ContentDepartment = $agent.ContentDept
                        SensitivityLabel = $labelApplied
                        RecipientName = $recipientName
                        RecipientUPN = $recipientUPN
                        Outcome = 'Success'
                    }

                Invoke-ActivityExplorerFileSignals -Token $token -SiteId $spoSiteId `
                    -Agent $agent -AgentUPN $upn -SourceItem $uploadResult `
                    -SourceFileName $fileName -SourcePath $targetPath -Folder $folder `
                    -SourceBytes $bytes -TimeStr $timeStr

                # -- Post activity in Teams department channel ----------------
                $deptDlp = $dlpPolicies[$agent.ContentDept]
                $labelTag = if ($labelApplied) { " | Label: <em>$labelApplied</em>" } else { '' }
                $htmlMsg = "<b>$($agent.Name)</b> ($($agent.Title)) a publie <b>$fileName</b> dans /$folder$labelTag<br/><small>Politiques DLP actives: $deptDlp</small>"
                Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $htmlMsg
            }
            catch {
                Write-Warning "    [$timeStr] Upload failed: $fileName -- $($_.Exception.Message)"
            }

            $fileIdx++
        }
        elseif ($activity.Type -eq 'email' -and $emailIdx -lt $emailCount) {
            $myScenarios = $emailScenariosBySam[$agent.Sam]
            if ($myScenarios) {
                $scenario = $myScenarios | Get-Random

                $deptDlp = $dlpPolicies[$agent.ContentDept]
                $emailPrompt = "$dayContext`n`nWrite a professional workplace email in English. Context: $($scenario.Context)`n`nFrom: $($agent.Name) ($($agent.Title))`nTo: a colleague`n`nIMPORTANT: End with this footer on a separate line:`n--- Classification: Confidential | DLP Policies: $deptDlp ---`nThis is a mandatory corporate compliance footer.`n`nOutput ONLY: first line = Subject, then blank line, then body. Include the sensitive data from the context when requested."

                try {
                    $emailContent = Invoke-OAI -OaiToken $oaiToken -SystemPrompt ($agent.Prompt + "`n`n" + $sitReference) -UserPrompt $emailPrompt -MaxTokens 800 -UserId $upn
                    $lines = $emailContent -split "`n", 3
                    $subject = ($lines[0] -replace '^(Objet|Subject)\s*:\s*', '').Trim()
                    $body    = if ($lines.Count -gt 2) { $lines[2].Trim() } else { $emailContent }
                }
                catch {
                    Write-Warning "    [$timeStr] OAI email failed: $($_.Exception.Message)"
                    $subject = $scenario.Context.Substring(0, [Math]::Min(60, $scenario.Context.Length))
                    $body    = "Hello,`n`n$($scenario.Context)`n`nRegards,`n$($agent.Name)"
                }

                $recipientUpn = "$($scenario.To)@$domain"
                $subject = ConvertTo-AASafeText -Text $subject -MaxLength 240
                $body = ConvertTo-AASafeText -Text $body -MaxLength 25000
                $emailPayload = @{
                    message = @{
                        subject      = $subject
                        body         = @{ contentType = 'Text'; content = $body }
                        toRecipients = @(@{ emailAddress = @{ address = $recipientUpn } })
                    }
                    saveToSentItems = $true
                }

                try {
                    Invoke-Graph -Token $token -Method POST `
                        -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $emailPayload | Out-Null
                    Write-Output "    [$timeStr] Email: $($agent.Sam) -> $($scenario.To) | $subject"
                    $totalEmails++
                    $recipientAgent = $agentLookup[$scenario.To]
                    $recipientName = if ($recipientAgent) { $recipientAgent.Name } else { $scenario.To }
                    Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                        -ActivityType 'email' -Detail "To:$($scenario.To) | $subject" `
                        -PromptContent $emailPrompt -ResponseContent $body `
                        -Properties @{
                            Service = 'Exchange Online'
                            Action = 'SentEmail'
                            Workload = 'Exchange'
                            TargetName = $subject
                            TargetType = 'Email'
                            RecipientName = $recipientName
                            RecipientUPN = $recipientUpn
                            Subject = $subject
                            Scenario = $scenario.Context
                            Outcome = 'Success'
                        }
                }
                catch {
                    Write-Warning "    [$timeStr] Email failed: $($_.Exception.Message)"
                }
            }
            $emailIdx++
        }

        # -- Simulate human delay between activities --------------------------
        if ($si -lt ($schedule.Count - 1)) {
            $nextTime = $schedule[$si + 1].Time
            $delay    = Get-DelaySeconds -CurrentTimeMin $activity.Time -NextTimeMin $nextTime
            Write-Output "    ... waiting ${delay}s (simulating work)"
            Start-Sleep -Seconds $delay
        }
    }

    # -- Compliance scan: detect unlabeled files in department folder --------
    $unlabeled = Get-UnlabeledFiles -Token $token -SiteId $spoSiteId -Folder $agent.Dept
    if ($unlabeled -and $unlabeled.Count -gt 0) {
        $fileList = ($unlabeled | Select-Object -First 5 | ForEach-Object { $_.name }) -join ', '
        $complianceHtml = "&#9888; <b>Compliance alert ($($agent.Dept))</b>: $($unlabeled.Count) unlabeled file(s) detected.<br/><small>Files: $fileList</small><br/><small>Recommended action: apply a sensitivity label in Microsoft Purview.</small>"
        Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $complianceHtml
        Write-Output "  [SCAN] $($unlabeled.Count) unlabeled files in /$($agent.Dept)"
    }
    else {
        $complianceHtml = "&#9989; <b>Compliance ($($agent.Dept))</b>: All files are labeled. Active DLP policies: $($dlpPolicies[$agent.ContentDept])"
        Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $complianceHtml
        Write-Output "  [SCAN] All files labeled in /$($agent.Dept)"
    }

    # -- Copilot M365 queries (Wave 2 agents with Copilot license) -----------
    $copilotCount = 0
    $copilotQueriesEnabled = $agentConfig.features.copilotQueries -ne $false
    if ($copilotQueriesEnabled -and (Test-ServiceRequested -Aliases @('copilot','microsoft 365 copilot','m365 copilot')) -and $copilotPrompts.ContainsKey($agent.Sam)) {
        try {
            # Generate unique search queries via Azure OpenAI per persona
            $dayContext = "Today is $(Get-Date -Format 'dddd d MMMM yyyy'). Generate queries relevant to this period."
            $aiQueries = Invoke-OAI -OaiToken $oaiToken `
                -SystemPrompt $copilotPrompts[$agent.Sam] `
                -UserPrompt $dayContext -UserId $upn
            $queryList = ($aiQueries -split "`n") | Where-Object { $_.Trim().Length -gt 5 } | Select-Object -First 3
            Write-Output "    [COPILOT] AI generated $($queryList.Count) search queries"
        }
        catch {
            Write-Warning "    [COPILOT] AI query generation failed, using fallback"
            $queryList = @(
                "$($agent.Dept) documents containing social security numbers or bank account data"
                "recent $($agent.Dept) files with sensitive personal data"
                "$($agent.Dept) reports $(Get-Date -Format 'MMMM yyyy')"
            )
        }

        foreach ($query in $queryList) {
            $query = $query.Trim()
            if ($query.Length -lt 5) { continue }
            try {
                $searchBody = @{
                    requests = @(
                        @{
                            entityTypes = @('driveItem')
                            query = @{ queryString = $query }
                            from = 0
                            size = 5
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $searchResult = Invoke-Graph -Token $token -Method POST `
                    -Uri 'https://graph.microsoft.com/v1.0/search/query' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($searchBody)) `
                    -ContentType 'application/json'

                $hitCount = 0
                if ($searchResult.value -and $searchResult.value[0].hitsContainers) {
                    $hitCount = $searchResult.value[0].hitsContainers[0].total
                }
                Write-Output "    [COPILOT] '$($query.Substring(0, [Math]::Min(60, $query.Length)))' -> $hitCount hits"
                $copilotCount++
                Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                    -ActivityType 'copilot' -Detail "Query: $($query.Substring(0, [Math]::Min(100, $query.Length))) -> $hitCount hits" `
                    -PromptContent $query -ResponseContent "$hitCount hits" `
                    -Properties @{
                        Service = 'Microsoft 365 Copilot'
                        Action = 'Searched'
                        Workload = 'Copilot'
                        TargetName = $query
                        TargetType = 'SearchQuery'
                        SearchQuery = $query
                        HitCount = $hitCount
                        Outcome = 'Success'
                    }

                Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 15)
            }
            catch {
                Write-Warning "    [COPILOT] Search failed: $($_.Exception.Message)"
            }
        }
    }

    # -- Controlled non-Copilot AI interactions (Devon expansion pack) -------
    $externalAiCount = 0
    $externalAiEnabled = $agentConfig.features.externalAiInteractions -eq $true
    $externalAiAliases = @('externalai','external ai','ai','foundry','azure ai foundry','deepseek','claude','grok','llama')
    if ($externalAiEnabled -and $agent.Workload -eq 'ExternalAI' -and (Test-ServiceRequested -Aliases $externalAiAliases)) {
        $externalAiResult = @(Invoke-ExternalAiSimulation -Agent $agent -Token $token -OaiToken $oaiToken -UserUpn $upn)
        foreach ($item in $externalAiResult) {
            if ($item -is [int]) {
                $externalAiCount = [int]$item
            } elseif ($item) {
                Write-Output $item
            }
        }
        $totalExternalAi += $externalAiCount
    }

    # -- Devon IRM data leak sequence ---------------------------------------
    $insiderRiskCount = 0
    $insiderRiskAliases = @('irm','insider risk','insider risk management','purview irm','risk','exfiltration','exfiltrate')
    if ($agent.Sam -eq 'devon.reyes' -and (Test-ServiceRequested -Aliases $insiderRiskAliases)) {
        $insiderRiskCount = Invoke-DevonInsiderRiskSequence -Agent $agent -Token $token -UserUpn $upn
        $totalInsiderRisk += $insiderRiskCount
    }

    Write-Output "  [DONE] $($agent.Name): $fileIdx files, $emailIdx emails, $copilotCount copilot queries, $externalAiCount external AI interactions, $insiderRiskCount insider risk events"
}

# =============================================================================
# MULTI-TURN EMAIL CONVERSATIONS (run after all agents complete individual work)
# Uses $agentLookup for O(1) agent resolution and caches ROPC tokens per sender.
# =============================================================================
$totalThreadEmails = 0
$threadTokenCache = @{}  # SAM -> ROPC token (avoid re-auth for same sender)
# Pick 1-2 random threads per run (not all 5 every day)
$runThreadEmails = Test-ServiceRequested -Aliases @('mail','email','exchange','exchange online','outlook','thread','threads')
$validThreads = @()
if ($runThreadEmails) {
    $validThreads = @($emailThreads | Where-Object {
        $valid = $true
        foreach ($m in $_.Messages) {
            if (-not $agentLookup[$m.From] -or -not $agentLookup[$m.To]) {
                $valid = $false
                break
            }
        }
        $valid
    })
} else {
    Write-Output "  [THREAD] Skipped by ServiceFilter."
}
if ($runThreadEmails -and $validThreads.Count -lt $emailThreads.Count) {
    Write-Output "  [THREAD] Skipping $($emailThreads.Count - $validThreads.Count) thread(s) with agents not present in current config."
}
$todayThreads = @()
if ($validThreads.Count -gt 0) {
    $todayThreads = $validThreads | Get-Random -Count ([Math]::Min(2, $validThreads.Count))
}

foreach ($thread in $todayThreads) {
    Write-Output "`n  [THREAD] $($thread.ThreadName) ($($thread.Messages.Count) messages)"
    $conversationHistory = ''

    foreach ($msg in $thread.Messages) {
        # O(1) agent lookup instead of Where-Object filter
        $senderAgent    = $agentLookup[$msg.From]
        $recipientAgent = $agentLookup[$msg.To]
        if (-not $senderAgent -or -not $recipientAgent) {
            Write-Warning "    [THREAD] Agent not found: $($msg.From) or $($msg.To)"
            continue
        }

        # Use cached ROPC token if available, otherwise authenticate
        $senderUpn = $senderAgent.Upn
        if ($threadTokenCache.ContainsKey($msg.From)) {
            $senderToken = $threadTokenCache[$msg.From]
        } else {
            $senderSecretName = Get-AutomationVariable -Name "AgentPwdSecret-$($msg.From)" -ErrorAction SilentlyContinue
            if (-not $senderSecretName) { $senderSecretName = $senderAgent.SecretName }
            $senderPwd = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $senderSecretName
            if (-not $senderPwd) {
                Write-Warning "    [THREAD] No password for $($msg.From)"
                continue
            }
            try {
                $senderToken = Get-ROPCToken -Username $senderUpn -Password $senderPwd `
                    -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
                $threadTokenCache[$msg.From] = $senderToken
            }
            catch {
                Write-Warning "    [THREAD] ROPC failed for $senderUpn"
                continue
            }
        }

        # Build the AI prompt with conversation history
        $threadPrompt = @"
You are $($senderAgent.Name), $($senderAgent.Title) at CorpLab.
You are writing an email to $($recipientAgent.Name) ($($recipientAgent.Title)).

$($msg.Instruction)

$(if ($conversationHistory) { "PREVIOUS MESSAGES IN THIS THREAD (include below your reply, prefixed with '> '):`n$conversationHistory" })

IMPORTANT RULES:
- Write in English
- Include the sensitive data mentioned in the instruction using realistic fake values only.
- For US social security numbers, use the keyword "social security number" near values formatted XXX-XX-XXXX.
- For bank data, use the keywords "routing number" and "account number" near realistic fake values.
- End with: --- Classification: Confidential | DLP Policies: $($dlpPolicies[$senderAgent.ContentDept]) ---
- Output: first line = Subject (with Re: or Tr: if reply/forward), blank line, then body
"@

        $subject = $null
        $body = $null
        try {
            $emailContent = Invoke-OAI -OaiToken $oaiToken `
                -SystemPrompt ($senderAgent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $threadPrompt -MaxTokens 1200 -UserId $senderUpn
            $elines = $emailContent -split "`n", 3
            $subject = ($elines[0] -replace '^(Objet|Subject)\s*:\s*', '').Trim()
            $body = if ($elines.Count -gt 2) { $elines[2].Trim() } else { $emailContent }
        }
        catch {
            Write-Warning "    [THREAD] OAI failed for $($senderAgent.Name) -> $($recipientAgent.Name); using fallback content. $($_.Exception.Message)"
            $subject = "Re: $($thread.ThreadName)"
            $historyNote = if ($conversationHistory) { "`n`nPrior context:`n$conversationHistory" } else { '' }
            $body = @"
Hello $($recipientAgent.Name),

$($msg.Instruction)

For the lab scenario, I am including realistic fake sensitive data only:
- social security number: 123-45-6789
- routing number: 021000021
- account number: 9988776655

Please review and advise on the next action.$historyNote

--- Classification: Confidential | DLP Policies: $($dlpPolicies[$senderAgent.ContentDept]) ---
"@
        }

        try {
            # Send the email
            $recipientUpn = "$($msg.To)@$domain"
            $subject = ConvertTo-AASafeText -Text $subject -MaxLength 240
            $body = ConvertTo-AASafeText -Text $body -MaxLength 25000
            $emailPayload = @{
                message = @{
                    subject = $subject
                    body = @{ contentType = 'Text'; content = $body }
                    toRecipients = @( @{ emailAddress = @{ address = $recipientUpn } } )
                }
                saveToSentItems = $true
            }

            Invoke-Graph -Token $senderToken -Method POST `
                -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' `
                -Body $emailPayload | Out-Null
            Write-Output "    [THREAD] $($senderAgent.Name) -> $($recipientAgent.Name) | $subject"
            $totalThreadEmails++
            Push-AgentActivity -AgentUPN $senderUpn -AgentName $senderAgent.Name -Department $senderAgent.Dept `
                -ActivityType 'thread' -Detail "To:$($msg.To) | $subject" `
                -PromptContent $threadPrompt -ResponseContent $body `
                -Properties @{
                    Service = 'Exchange Online'
                    Action = 'SentThreadEmail'
                    Workload = 'Exchange'
                    TargetName = $thread.ThreadName
                    TargetType = 'EmailThread'
                    RecipientName = $recipientAgent.Name
                    RecipientUPN = $recipientUpn
                    Subject = $subject
                    ThreadName = $thread.ThreadName
                    Scenario = $msg.Instruction
                    Outcome = 'Success'
                }

            # Add to conversation history for next message
            $conversationHistory += "`nFrom: $($senderAgent.Name) ($($senderAgent.Title))`nSubject: $subject`n$body`n---`n"
            $conversationHistory = ConvertTo-AASafeText -Text $conversationHistory -MaxLength 12000

            # Realistic delay between messages in a thread (1-3 minutes)
            Start-Sleep -Seconds (Get-Random -Minimum 10 -Maximum 45)
        }
        catch {
            Write-Warning "    [THREAD] Send failed: $($senderAgent.Name) -> $($recipientAgent.Name): $($_.Exception.Message)"
        }
    }
}

Write-Output "`n=== COMPLETE: $totalFiles files uploaded, $($script:totalFileOps) file operations, $totalEmails emails + $totalThreadEmails thread emails sent, $totalExternalAi external AI interactions, $totalInsiderRisk insider risk events ==="





