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

