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
    catch { Write-Error "Failed to parse AgentLocale variable: $($_.Exception.Message). Re-run Step 5 (Deploy-Runbook.ps1) to republish it." }
}
if ($locale -and -not $locale.country) {
    Write-Error "AgentLocale variable has no 'country' field. Re-run Step 5 (Deploy-Runbook.ps1) with a current config/locales/<COUNTRY>.json."
    $locale = $null
}
if (-not $locale) {
    # Legacy-coherent fallback: every hardcoded fallback below (SIT reference,
    # file types, scan templates) is French, so force FR instead of mixing
    # tenant.country PII shapes with French document prompts. The Write-Error
    # above (or this one) makes the degraded mode visible in the job errors.
    Write-Error "AgentLocale Automation variable is missing or invalid. Falling back to LEGACY FRENCH content (NIR / IBAN FR) regardless of the configured country. Re-run Step 5 (Deploy-Runbook.ps1) to publish the locale."
}
$country = if ($locale) { ([string]$locale.country).Trim().ToUpper() } else { 'FR' }
$companyDesc = if ($locale -and $locale.companyDescription) { $locale.companyDescription } else { 'a global company' }
# Content language follows the locale (fr -> French docs/emails, de -> German).
$contentLanguage = 'English'
if ($locale -and $locale.language) {
    switch (([string]$locale.language).Trim().ToLower()) {
        'fr'    { $contentLanguage = 'French' }
        'de'    { $contentLanguage = 'German' }
        default { $contentLanguage = 'English' }
    }
}

# Fabric / OneLake settings
$fabricEnabled      = $agentConfig.infrastructure.fabricEnabled -eq $true
$fabricWorkspaceId  = Get-AutomationVariable -Name 'AgentFabricWorkspaceId' -ErrorAction SilentlyContinue
$fabricLakehouseId  = Get-AutomationVariable -Name 'AgentFabricLakehouseId' -ErrorAction SilentlyContinue

# SIT precision reference (from Automation variable, with hardcoded fallback below)
$sitReferenceFromVar = Get-AutomationVariable -Name 'AgentSitReference' -ErrorAction SilentlyContinue

# Sensitivity label mapping: file type -> label name per department
# Labels are resolved at runtime from Graph Beta API.
# High lists cover the file type names of ALL locales (FR, US, UK, DE): the
# runbook only sees type names from the active AgentLocale, so a union is safe
# (names never collide across departments) and keeps High labels working for
# every country instead of only FR.
$labelRules = @{
    HR = @{
        High = @(
            'Paie_Mensuelle','Fiche_Employe','DPAE_Declaration','Registre_Personnel','Entretien_Annuel',                     # FR
            'Pay_Stub','Employee_Record','I9_Verification','W2_Statement','Employee_Roster','Annual_Review',                 # US
            'Payslip','HMRC_Starter','P60_Certificate','Staff_Register','Annual_Appraisal',                                  # UK
            'Lohnabrechnung','Personalakte','SV_Anmeldung','Lohnsteuerbescheinigung','Personalregister','Jahresgespraech'    # DE
        )
        HighLabel    = 'Conf-HR'
        DefaultLabel = 'Confidential/All Employees'
    }
    Finance = @{
        High = @(
            'Virements_Fournisseurs','DSN_Mensuelle','Facture',              # FR
            'Vendor_Payments','Form_1099','Invoice',                          # US
            'Supplier_Payments','P11D_Benefits',                              # UK (Invoice shared with US)
            'Lieferantenzahlungen','Umsatzsteuervoranmeldung','Rechnung'      # DE
        )
        HighLabel    = 'Conf-Finance'
        DefaultLabel = 'Confidential/All Employees'
    }
    Legal = @{
        High = @(
            'Audit_CNIL','Contentieux','Contrat_CDI',                         # FR
            'Compliance_Audit','Litigation_File','Employment_Agreement',      # US
            'ICO_Audit','Employment_Contract',                                # UK (Litigation_File shared with US)
            'Datenschutz_Audit','Rechtsstreit','Arbeitsvertrag'               # DE
        )
        HighLabel    = 'Highly Confidential/All Employees'
        DefaultLabel = 'Confidential/All Employees'
    }
    Engineering = @{
        High = @('TestData_PII','Incident_Report','Code_Review')              # universal (Engineering types are not localized)
        HighLabel    = 'Confidential/All Employees'
        DefaultLabel = 'General/All Employees'
    }
    Sales = @{
        High = @(
            'Pipeline_Commercial','Commissions','Proposition_Commerciale',    # FR
            'Sales_Pipeline','Commission_Report','Proposal',                  # US + UK
            'Vertriebspipeline','Provisionsbericht','Angebot'                 # DE
        )
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

