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
- Follow the MANDATORY DATA FORMAT RULES provided below: they define the exact sensitive data formats and keywords for the $country locale.
- Use realistic workplace names, emails, phone numbers, file names, and business context.
- Include sensitive data only when the activity or scenario calls for it.
Write in $contentLanguage. Never mention you are an AI.
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

