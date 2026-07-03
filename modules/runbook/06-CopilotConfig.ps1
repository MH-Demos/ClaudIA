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
        $langNote = "in $contentLanguage"
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

