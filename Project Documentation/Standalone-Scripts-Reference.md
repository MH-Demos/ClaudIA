# Standalone Scripts Reference

Generated from the current PowerShell scripts in the repository. It focuses on scripts that can be executed directly from the project root, `tools`, `tests`, and `prerequisites`.

> Recommended convention: run commands from the repository root unless the script documentation says otherwise.

## Quick Index

- [`Install-AutonomousAgents.ps1`](#install-autonomousagents-ps1)
- [`Manage-Costs.ps1`](#manage-costs-ps1)
- [`prerequisites/Test-Prerequisites.ps1`](#prerequisites-test-prerequisites-ps1)
- [`tests/Test-AgentCredentials.ps1`](#tests-test-agentcredentials-ps1)
- [`tests/Test-AzureOpenAI.ps1`](#tests-test-azureopenai-ps1)
- [`tests/Test-FullRun.ps1`](#tests-test-fullrun-ps1)
- [`tests/Test-SingleAgent.ps1`](#tests-test-singleagent-ps1)
- [`tools/Add-StorylineAgents.ps1`](#tools-add-storylineagents-ps1)
- [`tools/Deploy-AdxTelemetry.ps1`](#tools-deploy-adxtelemetry-ps1)
- [`tools/Deploy-BrowserAgentInfra.ps1`](#tools-deploy-browseragentinfra-ps1)
- [`tools/Deploy-BrowserAgentScheduledJobs.ps1`](#tools-deploy-browseragentscheduledjobs-ps1)
- [`tools/Enable-ActivityStoryMapFrontDoor.ps1`](#tools-enable-activitystorymapfrontdoor-ps1)
- [`tools/Enable-GraphMeteredBilling.ps1`](#tools-enable-graphmeteredbilling-ps1)
- [`tools/Get-ActivityExplorerFileOps.ps1`](#tools-get-activityexplorerfileops-ps1)
- [`tools/Get-BrowserAgentScheduledJobStatus.ps1`](#tools-get-browseragentscheduledjobstatus-ps1)
- [`tools/Get-BrowserAgentTelemetry.ps1`](#tools-get-browseragenttelemetry-ps1)
- [`tools/Get-LabelActivity.ps1`](#tools-get-labelactivity-ps1)
- [`tools/Get-RunbookStatus.ps1`](#tools-get-runbookstatus-ps1)
- [`tools/Initialize-BrowserAgents.ps1`](#tools-initialize-browseragents-ps1)
- [`tools/Initialize-StorylineEntraUsers.ps1`](#tools-initialize-storylineentrausers-ps1)
- [`tools/Install-CleanAdxLab.ps1`](#tools-install-cleanadxlab-ps1)
- [`tools/Install-LiveDemoMay272026ExpansionPack.ps1`](#tools-install-livedemomay272026expansionpack-ps1)
- [`tools/Invoke-ActivityStoryMapRefresh.ps1`](#tools-invoke-activitystorymaprefresh-ps1)
- [`tools/Invoke-BrowserAgentAuth.ps1`](#tools-invoke-browseragentauth-ps1)
- [`tools/Invoke-BrowserAgentDaily.ps1`](#tools-invoke-browseragentdaily-ps1)
- [`tools/Invoke-BrowserAgentScheduledRun.ps1`](#tools-invoke-browseragentscheduledrun-ps1)
- [`tools/Invoke-BrowserAgentSmoke.ps1`](#tools-invoke-browseragentsmoke-ps1)
- [`tools/Invoke-EdgePersonaActivity.ps1`](#tools-invoke-edgepersonaactivity-ps1)
- [`tools/Invoke-EndpointPersonaActivity.ps1`](#tools-invoke-endpointpersonaactivity-ps1)
- [`tools/List-AzureOpenAIModels.ps1`](#tools-list-azureopenaimodels-ps1)
- [`tools/Publish-ActivityStoryMapAssets.ps1`](#tools-publish-activitystorymapassets-ps1)
- [`tools/Publish-LiveDemoSeedContent.ps1`](#tools-publish-livedemoseedcontent-ps1)
- [`tools/Publish-RunbookOnly.ps1`](#tools-publish-runbookonly-ps1)
- [`tools/Reset-AgentPasswords.ps1`](#tools-reset-agentpasswords-ps1)
- [`tools/Set-AzureOpenAIName.ps1`](#tools-set-azureopenainame-ps1)
- [`tools/Test-BrowserAgentWorkspace.ps1`](#tools-test-browseragentworkspace-ps1)
- [`tools/Test-InstallationDefinitionsConsistency.ps1`](#tools-test-installationdefinitionsconsistency-ps1)
- [`tools/Update-ActivityStoryMapCharacterProfiles.ps1`](#tools-update-activitystorymapcharacterprofiles-ps1)

## `Install-AutonomousAgents.ps1`

**Purpose:** ClaudIA - Interactive Deployment Wizard

**Details:** Single entry point to deploy autonomous data-generation agents that simulate corporate employees in an M365 tenant. Generates realistic PII content (files, emails, Teams posts, Copilot queries) for Purview DLP/IRM/DSPM testing. Supports two user modes: - CREATE (default): Creates new Entra ID users from agents.json personas - EXISTING: Interactive picker to select existing tenant users as agents WARNING: Uses ROPC (Resource Owner Password Credentials) which bypasses MFA. FOR LAB AND DEMO USE ONLY. Do NOT deploy in production environments.

**Base command:**

```powershell
.\Install-AutonomousAgents.ps1
```

**Examples from script help:**

```powershell
.\Install-AutonomousAgents.ps1
.\Install-AutonomousAgents.ps1 -UseExistingUsers
.\Install-AutonomousAgents.ps1 -Step 4 -SkipPrerequisites
.\Install-AutonomousAgents.ps1 -DryRun
=== WIZARD FLOW (9 steps, all idempotent) ===
Step 0: PREREQUISITES
Runs Test-Prerequisites.ps1 (13 checks: tools, providers, licenses, permissions).
-> Skip with -SkipPrerequisites if you already validated.
Step 1: CREATE OR SELECT AGENTS
Mode 'create': Creates Entra ID users from agents.json, generates shared password.
Mode 'existing': Launches interactive picker (Select-ExistingUsers.ps1).
Mode 'prompt': Asks which mode at runtime.
-> Customize via -UseExistingUsers switch or features.userMode in agents.json.
Step 2: LICENSES + MFA EXCLUSION
Assigns M365 E5 (all agents) + Copilot (Wave 2) licenses via Graph API.
Creates grp-agent-mfa-exclusion security group and adds all agents.
-> MANUAL: Exclude this group from your Conditional Access MFA policy.
Step 3: REGISTER ENTRA APP
Creates app-dataagent with 11 delegated scopes for ROPC.
-> Calls modules/Register-AgentApp.ps1.
Step 4: DEPLOY AZURE INFRASTRUCTURE
Creates: Resource Group, Azure OpenAI (S0), Automation (Basic), and Key Vault access.
ADX telemetry is provisioned with tools/Deploy-AdxTelemetry.ps1 after Step 4.
-> Calls modules/Deploy-AzureInfra.ps1.
Step 4a: M365 COLLABORATION
Creates SharePoint site + Teams team + department channels + folders.
Adds all agents as team members. Stores IDs in Automation variables.
-> Calls modules/Provision-M365Collaboration.ps1.
Step 4b: SENSITIVITY LABELS
Creates 5 labels (General, Confidential, Conf-HR, Conf-Finance, Highly Confidential).
Publishes label policy. Labels take 24-48h to propagate.
-> Calls modules/Provision-SensitivityLabels.ps1.
Step 4c: FABRIC PROVISIONING (conditional)
Creates F2 capacity, workspace, and lakehouse for OneLake dual-write.
Only runs if fabricEnabled=true in agents.json.
-> Calls modules/Provision-Fabric.ps1.
Step 5: STORE SECRETS + DEPLOY RUNBOOK
Stores agent passwords and app secret in Key Vault, plus non-secret
config/secret names as Automation variables.
Uploads and publishes the runbook. Creates 3 daily schedules.
-> Calls modules/Deploy-Runbook.ps1.
Step 6: CONFIGURE PURVIEW (DLP + IRM)
Creates 3 DSPM DLP policies. Prints IRM manual steps.
-> Calls modules/Configure-DLP.ps1.
Step 7: DEPLOY WORKBOOK
Deploys Agent Activity Monitor Azure workbook (8 KQL sections).
-> Calls modules/Deploy-Workbook.ps1.
Step 8: DEPLOY ACTIVITY STORY MAP
Deploys an Azure Storage static website and Azure Function backed by ADX.
-> Calls modules/Deploy-ActivityStoryMap.ps1.

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No |  | Path to the main configuration file, usually `config/agents.json`. |
| `-SkipPrerequisites` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-Step` | `int` | No | `0` | Run a specific installer step only. |
| `-DryRun` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-UseExistingUsers` | `switch` | No |  | Use existing Entra users as agents instead of creating default users. |
| `-UseInstallationDefinitions` | `switch` | No |  | Reuse values from `config/Installation_definitions.json` instead of prompting for fresh setup details. |
| `-Auto` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-AgentPassword` | `string` | No |  | Script-specific option. See the script help and examples before use. |

## `Manage-Costs.ps1`

**Purpose:** Cost management utilities for the Autonomous Agents lab.

**Details:** Check current Azure spend, estimate monthly costs, pause/resume Fabric, adjust schedules, and get optimization recommendations.

**Base command:**

```powershell
.\Manage-Costs.ps1
```

**Examples from script help:**

```powershell
.\Manage-Costs.ps1 -Action Status
.\Manage-Costs.ps1 -Action PauseFabric
.\Manage-Costs.ps1 -Action Recommendations
=== COST LEVERS (what you can control) ===
1. AGENT COUNT: Edit agents.json to reduce from 10 to 5 (Wave 1 only).
Impact: ~50% reduction in OpenAI tokens and Automation runtime.
2. SCHEDULE FREQUENCY: Use ReduceSchedule action (3x/day -> 1x/day).
Impact: ~66% reduction in Automation + OpenAI costs.
3. FABRIC CAPACITY: Use PauseFabric action when not demoing.
Impact: Saves $262/month (largest single cost item).
4. OPENAI MODEL: Change infrastructure.openAiModel in agents.json.
GPT-4o-mini ($0.15/1M tokens) vs GPT-4o ($2.50/1M tokens).
5. FILE FREQUENCY: Reduce filesPerDay/emailsPerDay per agent in agents.json.
Impact: Fewer OpenAI calls per run.

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Action` | `string` | Yes |  | Script-specific option. See the script help and examples before use. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot 'config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |

## `prerequisites/Test-Prerequisites.ps1`

**Purpose:** Checks all prerequisites for deploying ClaudIA.

**Details:** Validates: Azure CLI, PowerShell modules, Azure subscription, M365 licenses, Entra permissions, provider registrations, and resource quotas. Returns a structured result with pass/fail for each check.

**Base command:**

```powershell
.\prerequisites\Test-Prerequisites.ps1
```

**Examples from script help:**

```powershell
$result = .\Test-Prerequisites.ps1
if (-not $result.AllPassed) { $result.Results | Where-Object { -not $_.Passed } }

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |

## `tests/Test-AgentCredentials.ps1`

**Purpose:** Validate app-dataagent client secret and one agent password from Key Vault.

**Details:** Reads the existing project config/installation definitions, resolves the selected agent UPN and Key Vault secret names, then validates: - app-dataagent client secret can obtain a client_credentials token - agent password can obtain a delegated ROPC Graph token By default it never prints secret values. Use -RevealSecretValues only in a lab.

**Base command:**

```powershell
.\tests\Test-AgentCredentials.ps1
```

**Examples from script help:**

```powershell
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez

.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez -ExpectedClientSecret 'value' -RevealSecretValues

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agent` | `string` | Yes |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-ExpectedClientSecret` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-ExpectedPassword` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-RepairConsent` | `switch` | No |  | Attempt to repair delegated Graph consent for the app registration. |
| `-RevealSecretValues` | `switch` | No |  | Reveal sensitive values for lab troubleshooting. Use carefully. |

## `tests/Test-AzureOpenAI.ps1`

**Purpose:** Validate the Azure OpenAI deployment used by the runbook.

**Details:** Uses the current Azure CLI identity to request a Cognitive Services token and calls the configured chat completions deployment with a minimal prompt. This isolates Azure OpenAI API/deployment errors from runbook execution.

**Base command:**

```powershell
.\tests\Test-AzureOpenAI.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-Prompt` | `string` | No | `'Write one short sentence in English for a lab test.'` | Prompt text sent to Azure OpenAI or a model test. |

## `tests/Test-FullRun.ps1`

**Purpose:** Run the agent runbook for all configured users and summarize results.

**Details:** Starts one Azure Automation job per selected agent, waits for completion, collects job output/diagnostics, waits for ADX ingestion, and prints a per-user activity table with Upload, Fabric, Copilot, Email, Teams, and status columns.

**Base command:**

```powershell
.\tests\Test-FullRun.ps1
```

**Examples from script help:**

```powershell
.\tests\Test-FullRun.ps1

.\tests\Test-FullRun.ps1 -Agents ana.rodriguez,priya.sharma -ADXWaitMinutes 2

.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 3

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-Agents` | `string[]` | No |  | One or more agent/persona selectors. Usually SAM names such as `priya.sharma`. |
| `-PollSeconds` | `int` | No | `45` | Script-specific option. See the script help and examples before use. |
| `-ADXWaitMinutes` | `int` | No | `2` | Minutes to wait for ADX ingestion before querying results. |
| `-Services` | `string[]` | No |  | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-AIServices` | `string[]` | No | `@('llama','claude','deepseek','grok')` | Script-specific option. See the script help and examples before use. |
| `-Parallel` | `switch` | No |  | Run supported operations concurrently. |
| `-ThrottleLimit` | `int` | No | `3` | Maximum number of concurrent operations when running in parallel. |
| `-StartRetrySeconds` | `int` | No | `60` | Script-specific option. See the script help and examples before use. |
| `-MaxStartRetries` | `int` | No | `10` | Script-specific option. See the script help and examples before use. |
| `-NoADXWait` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-BrowserAgent` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-BrowserServices` | `string[]` | No | `@('owa','copilot')` | Script-specific option. See the script help and examples before use. |
| `-ExternalRecipient` | `string` | No | `'demo.recipient@example.com'` | External mailbox target for OWA scenarios. Comma-separated values are supported. |
| `-SendEmail` | `switch` | No |  | Actually send OWA messages instead of only drafting/composing them. |
| `-Sensitive` | `switch` | No |  | Include synthetic sensitive business or personal data in generated activity. |
| `-Label` | `string` | No | `''` | Sensitivity label name to attempt to apply in supported browser/mail flows. |
| `-SkipBrowserPreflight` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ContinueOnFailure` | `switch` | No |  | Continue processing remaining agents/items after an error. |

## `tests/Test-SingleAgent.ps1`

**Purpose:** Quick test: run a single agent and verify data in Azure Data Explorer.

**Base command:**

```powershell
.\tests\Test-SingleAgent.ps1
```

**Examples from script help:**

```powershell
.\Test-SingleAgent.ps1 -Agent ana.rodriguez

.\Test-SingleAgent.ps1 -Agent devon.reyes -Services llama

.\Test-SingleAgent.ps1 -Agent devon.reyes -Services mail, Teams, Claude

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agent` | `string` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-Services` | `string[]` | No | `@()` | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-BrowserAgent` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-BrowserServices` | `string[]` | No | `@('owa','copilot')` | Script-specific option. See the script help and examples before use. |
| `-ExternalRecipient` | `string` | No | `'demo.recipient@example.com'` | External mailbox target for OWA scenarios. Comma-separated values are supported. |
| `-SendEmail` | `switch` | No |  | Actually send OWA messages instead of only drafting/composing them. |
| `-Sensitive` | `switch` | No |  | Include synthetic sensitive business or personal data in generated activity. |
| `-Label` | `string` | No | `''` | Sensitivity label name to attempt to apply in supported browser/mail flows. |
| `-SkipBrowserPreflight` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-Help` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ConfigPath` | `string` | No | `''` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `''` | Path to installation definitions JSON used for resumable setup state. |

## `tools/Add-StorylineAgents.ps1`

**Purpose:** Add existing Entra ID users as storyline expansion agents without duplicates.

**Details:** Reads config/agents.json and Storyline/profiles.md, lists tenant users that are not already configured as agents, and appends selected users to agents.json. This script can also act as an "expansion pack installer": reset selected users to a generated/shared password, store one Key Vault secret per selected user, and update the existing Automation Account variables needed by the current runbook. This avoids re-running the interactive Step 1 picker.

**Base command:**

```powershell
.\tools\Add-StorylineAgents.ps1
```

**Examples from script help:**

```powershell
.\tools\Add-StorylineAgents.ps1

.\tools\Add-StorylineAgents.ps1 -Search Sofia

.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles -ResetPassword -StoreInKeyVault -UpdateAutomationVariables

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-ProfilesPath` | `string` | No | `(Join-Path $PSScriptRoot '..\Storyline\profiles.md')` | Path to a Storyline profile source file. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-Search` | `string` | No | `''` | Filter/select matching users or profiles by text. |
| `-AutoFromProfiles` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ResetPassword` | `switch` | No |  | Reset selected agent passwords and store/update resulting secrets where supported. |
| `-NoPasswordReset` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-StoreInKeyVault` | `switch` | No |  | Store generated credentials in Azure Key Vault. |
| `-UpdateAutomationVariables` | `switch` | No |  | Update Azure Automation variables to point to current configuration/secrets. |
| `-AgentPassword` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-RevealPassword` | `switch` | No |  | Reveal sensitive values for lab troubleshooting. Use carefully. |

## `tools/Deploy-AdxTelemetry.ps1`

**Purpose:** Deploy Azure Data Explorer telemetry resources for autonomous agent activity.

**Details:** Creates an ADX cluster, an ADX database, the agent activity table, JSON ingestion mapping, streaming ingestion policy, and a Database Ingestor principal assignment for the configured application. The script reads and updates config/Installation_definitions.json by default. It is idempotent and can be run again after the cluster finishes provisioning.

**Base command:**

```powershell
.\tools\Deploy-AdxTelemetry.ps1
```

**Examples from script help:**

```powershell
.\tools\Deploy-AdxTelemetry.ps1 -WhatIf

.\tools\Deploy-AdxTelemetry.ps1

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-TenantId` | `string` | No |  | Microsoft Entra tenant ID. |
| `-ClientId` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-ClientSecret` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-ClientSecretName` | `string` | No | `'agent-client-secret'` | Script-specific option. See the script help and examples before use. |
| `-M365Scope` | `string` | No | `'https://manage.office.com/.default'` | Script-specific option. See the script help and examples before use. |
| `-PreferredSku` | `string` | No | `'Dev(No SLA)_Standard_E2a_v4'` | Script-specific option. See the script help and examples before use. |
| `-WhatIf` | `switch` | No |  | PowerShell ShouldProcess preview mode; show intended operations without applying them. |

## `tools/Deploy-BrowserAgentInfra.ps1`

**Purpose:** Deploys the Azure Playwright Workspace used by BrowserAgents.

**Details:** Creates or updates a Microsoft.LoadTestService/playwrightWorkspaces resource in the lab subscription. The workspace provides cloud-hosted browsers for Office Web, OWA, SharePoint Web, and SaaS upload/paste automation.

**Base command:**

```powershell
.\tools\Deploy-BrowserAgentInfra.ps1
```

**Examples from script help:**

```powershell
.\tools\Deploy-BrowserAgentInfra.ps1

.\tools\Deploy-BrowserAgentInfra.ps1 -Location eastus -WorkspaceName pw-aa-claudia-lab

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-SubscriptionId` | `string` | No | `''` | Azure subscription ID used for Azure CLI/ARM operations. |
| `-ResourceGroup` | `string` | No | `''` | Azure resource group containing or receiving the lab resources. |
| `-Location` | `string` | No | `'eastus'` | Azure region for resources created by the script. |
| `-WorkspaceName` | `string` | No | `'pw-aa-claudia-lab'` | Azure Playwright Workspace name. |
| `-AssignCurrentUserRole` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Deploy-BrowserAgentScheduledJobs.ps1`

**Purpose:** Deploys BrowserAgents as scheduled Azure Container Apps Jobs.

**Details:** Builds the BrowserAgents container image into a private Azure Container Registry, creates a Container Apps environment, and creates one scheduled job per schedule defined in config\agents.json. The container image includes BrowserAgents\.auth session state files so the Azure job can run without interactive sign-in. This is intentionally a lab shortcut; refresh those sessions regularly and keep the ACR private.

**Base command:**

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1
```

**Examples from script help:**

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1 -WhatIf

.\tools\Deploy-BrowserAgentScheduledJobs.ps1 -Deploy -Services owa,copilot -ExternalRecipient demo.recipient@example.com

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-SubscriptionId` | `string` | No | `''` | Azure subscription ID used for Azure CLI/ARM operations. |
| `-ResourceGroup` | `string` | No | `''` | Azure resource group containing or receiving the lab resources. |
| `-Location` | `string` | No | `''` | Azure region for resources created by the script. |
| `-AcrName` | `string` | No | `''` | Azure Container Registry name used for BrowserAgent container images. |
| `-EnvironmentName` | `string` | No | `''` | Azure Container Apps managed environment name. |
| `-ManagedIdentityName` | `string` | No | `''` | User-assigned managed identity name for Container Apps Jobs. |
| `-JobNamePrefix` | `string` | No | `'browseragents'` | Prefix used to name Azure Container Apps Jobs for scheduled BrowserAgents. |
| `-ImageName` | `string` | No | `'browseragents'` | Container image repository/tag for BrowserAgent scheduled jobs. |
| `-ImageTag` | `string` | No | `'latest'` | Container image repository/tag for BrowserAgent scheduled jobs. |
| `-Agents` | `string[]` | No |  | One or more agent/persona selectors. Usually SAM names such as `priya.sharma`. |
| `-Services` | `string[]` | No | `@('owa','copilot')` | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-ExternalRecipient` | `string` | No | `'demo.recipient@example.com'` | External mailbox target for OWA scenarios. Comma-separated values are supported. |
| `-SendEmail` | `switch` | No |  | Actually send OWA messages instead of only drafting/composing them. |
| `-Sensitive` | `switch` | No |  | Include synthetic sensitive business or personal data in generated activity. |
| `-Label` | `string` | No | `'General'` | Sensitivity label name to attempt to apply in supported browser/mail flows. |
| `-BrowserRegionKey` | `string` | No | `''` | Regional BrowserAgent workspace key from `browserAgents.regionalWorkspaces`, such as `americas`, `europe`, or `asia`. |
| `-PlaywrightWorkspaceName` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-PlaywrightServiceUrl` | `string` | No | `''` | Explicit Azure Playwright browser websocket endpoint. |
| `-ReplicaTimeoutSeconds` | `int` | No | `3600` | Script-specific option. See the script help and examples before use. |
| `-Cpu` | `double` | No | `2.0` | Script-specific option. See the script help and examples before use. |
| `-Memory` | `string` | No | `'4Gi'` | Script-specific option. See the script help and examples before use. |
| `-WeekendActivityPercent` | `int` | No | `25` | Percentage of selected agents to run on Saturday/Sunday. |
| `-SkipAgentsMissingAuth` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-Deploy` | `switch` | No |  | Execute changes. Without it, many deploy scripts run in plan/preview mode. |

## `tools/Enable-ActivityStoryMapFrontDoor.ps1`

**Purpose:** Enables Azure Front Door for the Activity Story Map static website.

**Details:** Creates or updates a Standard Azure Front Door profile, endpoint, origin group, origin, route, and optional custom domain for the Activity Story Map. The frontend still calls the Azure Function API directly through config.js, so the script also adds the Front Door hostnames to Function App CORS.

**Base command:**

```powershell
.\tools\Enable-ActivityStoryMapFrontDoor.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-CustomDomain` | `string` | No | `'activitymap.contoso.example'` | Script-specific option. See the script help and examples before use. |
| `-EndpointName` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-WhatIf` | `switch` | No |  | PowerShell ShouldProcess preview mode; show intended operations without applying them. |

## `tools/Enable-GraphMeteredBilling.ps1`

**Purpose:** Enables Microsoft Graph metered API billing for the lab app registration.

**Details:** Creates or reuses a Microsoft.GraphServices/accounts resource associated with the configured app-dataagent application registration. This is required for metered APIs such as SharePoint/OneDrive assignSensitivityLabel.

**Base command:**

```powershell
.\tools\Enable-GraphMeteredBilling.ps1
```

**Examples from script help:**

```powershell
.\tools\Enable-GraphMeteredBilling.ps1 -SubscriptionId ab97362c-5d5f-49a5-bf87-c8480e54e062 -ResourceGroup MH-Agents-PAYG

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-SubscriptionId` | `string` | Yes |  | Azure subscription ID used for Azure CLI/ARM operations. |
| `-ResourceGroup` | `string` | Yes |  | Azure resource group containing or receiving the lab resources. |
| `-Location` | `string` | No | `'eastus'` | Azure region for resources created by the script. |
| `-GraphResourceName` | `string` | No | `'graph-metered-app-dataagent'` | Script-specific option. See the script help and examples before use. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-AppId` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |

## `tools/Get-ActivityExplorerFileOps.ps1`

**Purpose:** Query recent low-complexity file operations generated for Purview Activity Explorer validation.

**Base command:**

```powershell
.\tools\Get-ActivityExplorerFileOps.ps1
```

**Examples from script help:**

```powershell
.\tools\Get-ActivityExplorerFileOps.ps1

.\tools\Get-ActivityExplorerFileOps.ps1 -Agent ana.rodriguez -SinceHours 6

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-SinceHours` | `int` | No | `24` | Script-specific option. See the script help and examples before use. |
| `-Agent` | `string` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-Top` | `int` | No | `100` | Maximum number of recent records/executions to return. |

## `tools/Get-BrowserAgentScheduledJobStatus.ps1`

**Purpose:** Shows recent BrowserAgent Azure Container Apps Job executions.

**Base command:**

```powershell
.\tools\Get-BrowserAgentScheduledJobStatus.ps1
```

**Examples from script help:**

```powershell
.\tools\Get-BrowserAgentScheduledJobStatus.ps1

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-SubscriptionId` | `string` | No | `''` | Azure subscription ID used for Azure CLI/ARM operations. |
| `-ResourceGroup` | `string` | No | `''` | Azure resource group containing or receiving the lab resources. |
| `-JobNamePrefix` | `string` | No | `'browseragents'` | Prefix used to name Azure Container Apps Jobs for scheduled BrowserAgents. |
| `-Top` | `int` | No | `10` | Maximum number of recent records/executions to return. |

## `tools/Get-BrowserAgentTelemetry.ps1`

**Purpose:** Query recent BrowserAgent telemetry from Azure Data Explorer.

**Base command:**

```powershell
.\tools\Get-BrowserAgentTelemetry.ps1
```

**Examples from script help:**

```powershell
.\tools\Get-BrowserAgentTelemetry.ps1

.\tools\Get-BrowserAgentTelemetry.ps1 -Agent priya.sharma -SinceMinutes 120

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-SinceMinutes` | `int` | No | `60` | Lookback window in minutes for telemetry or status queries. |
| `-Agent` | `string` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-Top` | `int` | No | `50` | Maximum number of recent records/executions to return. |

## `tools/Get-LabelActivity.ps1`

**Purpose:** Query recent sensitivity label activity from ADX telemetry.

**Base command:**

```powershell
.\tools\Get-LabelActivity.ps1
```

**Examples from script help:**

```powershell
.\tools\Get-LabelActivity.ps1

.\tools\Get-LabelActivity.ps1 -Agent laura.gomez -SinceHours 24

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-SinceHours` | `int` | No | `24` | Script-specific option. See the script help and examples before use. |
| `-Agent` | `string` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-Top` | `int` | No | `100` | Maximum number of recent records/executions to return. |

## `tools/Get-RunbookStatus.ps1`

**Purpose:** Show recent Azure Automation runbook executions for the autonomous agents lab.

**Details:** Reads the effective installation configuration, resolves the Automation Account, lists recent Invoke-AgentRunbook jobs, and prints a compact status table. Use -IncludeStreams to fetch warning/error stream counts and recent diagnostic snippets for each job. The script does not start jobs and has no Log Analytics dependency.

**Base command:**

```powershell
.\tools\Get-RunbookStatus.ps1
```

**Examples from script help:**

```powershell
.\tools\Get-RunbookStatus.ps1

.\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams

.\tools\Get-RunbookStatus.ps1 -Agent laura.gomez -IncludeStreams

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-Last` | `int` | No | `15` | Script-specific option. See the script help and examples before use. |
| `-SinceHours` | `int` | No | `48` | Script-specific option. See the script help and examples before use. |
| `-Agent` | `string` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-IncludeStreams` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-IncludeOutput` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ShowSchedules` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Initialize-BrowserAgents.ps1`

**Purpose:** Initialize and validate BrowserAgent sessions for one or more M365 personas.

**Details:** For each selected agent, this script can capture or refresh the browser session state, then validates access to individual web services such as Office/M365, OWA, Copilot/Copilot Chat, and Teams.

**Base command:**

```powershell
.\tools\Initialize-BrowserAgents.ps1
```

**Examples from script help:**

```powershell
.\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma

.\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma,ana.rodriguez -RefreshAuth -Services office,owa,copilot

.\tools\Initialize-BrowserAgents.ps1 -All -Services office,owa -SkipAuth

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agents` | `string[]` | No |  | One or more agent/persona selectors. Usually SAM names such as `priya.sharma`. |
| `-All` | `switch` | No |  | Select all configured agents. |
| `-Services` | `string[]` | No | `@('office','owa','copilot','teams')` | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-RefreshAuth` | `switch` | No |  | Refresh browser session state by running interactive auth capture. |
| `-SkipAuth` | `switch` | No |  | Skip auth capture and use existing browser session state. |
| `-Azure` | `switch` | No |  | Run with Azure Playwright Workspaces instead of local Chromium where supported. |
| `-ContinueOnFailure` | `switch` | No |  | Continue processing remaining agents/items after an error. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-BrowserAgentsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\BrowserAgents')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |
| `-ResultsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\BrowserAgents\test-results\preflight')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |

## `tools/Initialize-StorylineEntraUsers.ps1`

**Purpose:** Create storyline users and license security groups in Microsoft Entra ID.

**Details:** Reads Storyline/characters_presentations.md, removes non-storyboard people (Sebastian, Karla, and Nabil by default), reviews existing Entra users and security groups, then creates missing users and the security groups used for group-based license assignment. By default the script creates: - grp-license-m365-e5: all storyline personas - grp-license-m365-copilot: personas whose profile/config requires Copilot Use -AssignLicensesToGroups only when the tenant is ready for group-based licensing and the selected SKU part numbers are correct.

**Base command:**

```powershell
.\tools\Initialize-StorylineEntraUsers.ps1
```

**Examples from script help:**

```powershell
.\tools\Initialize-StorylineEntraUsers.ps1 -DryRun

.\tools\Initialize-StorylineEntraUsers.ps1 -AutoApprove -RevealPassword

.\tools\Initialize-StorylineEntraUsers.ps1 -AssignLicensesToGroups -M365SkuPartNumber SPE_E5 -CopilotSkuPartNumber Microsoft_365_Copilot

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ProfilesPath` | `string` | No | `(Join-Path $PSScriptRoot '..\Storyline\characters_presentations.md')` | Path to a Storyline profile source file. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-Domain` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-UsageLocation` | `string` | No | `'US'` | Script-specific option. See the script help and examples before use. |
| `-InitialPassword` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-RevealPassword` | `switch` | No |  | Reveal sensitive values for lab troubleshooting. Use carefully. |
| `-ForceChangePasswordNextSignIn` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-UpdateExistingUsers` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-AssignLicensesToGroups` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-M365SkuPartNumber` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-CopilotSkuPartNumber` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-ExcludeNames` | `string[]` | No | `@('Sebastian Zamorano', 'Sebastian "Kaz" Zamorano', 'Sebastian “Kaz” Zamorano', 'Karla Penzo', 'Nabil Senoussaoui')` | Script-specific option. See the script help and examples before use. |
| `-M365LicenseGroupName` | `string` | No | `'grp-license-m365-e5'` | Script-specific option. See the script help and examples before use. |
| `-CopilotLicenseGroupName` | `string` | No | `'grp-license-m365-copilot'` | Script-specific option. See the script help and examples before use. |
| `-DryRun` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-AutoApprove` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Install-CleanAdxLab.ps1`

**Purpose:** Clean end-to-end installer for an ADX-backed autonomous agents lab.

**Details:** Orchestrates the existing installer/modules in the intended order for a new subscription/resource group while keeping agent telemetry in Azure Data Explorer. The script updates config/agents.json, runs the base wizard steps, provisions ADX, publishes the runbook with ADX config, optionally adds storyline agents, and can run a smoke test.

**Base command:**

```powershell
.\tools\Install-CleanAdxLab.ps1
```

**Examples from script help:**

```powershell
.\tools\Install-CleanAdxLab.ps1 `
-SubscriptionId 00000000-0000-0000-0000-000000000000 `
-ResourceGroup IA-NewDemo `
-Location eastus `
-AutomationAccountName newdemo-agents `
-OpenAiAccountName oai-newdemo-1234 `
-KeyVaultName kvnewdemo1234 `
-AdxClientSecret "<secret>" `
-UseExistingUsers `
-Auto

.\tools\Install-CleanAdxLab.ps1 -DryRun

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No |  | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No |  | Path to installation definitions JSON used for resumable setup state. |
| `-SubscriptionId` | `string` | No |  | Azure subscription ID used for Azure CLI/ARM operations. |
| `-ResourceGroup` | `string` | No |  | Azure resource group containing or receiving the lab resources. |
| `-Location` | `string` | No |  | Azure region for resources created by the script. |
| `-Domain` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-AutomationAccountName` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-OpenAiAccountName` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-KeyVaultName` | `string` | No |  | Azure Key Vault name. |
| `-AdxTenantId` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-AdxClientId` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-AdxClientSecret` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-AdxClientSecretName` | `string` | No | `'agent-client-secret'` | Script-specific option. See the script help and examples before use. |
| `-AdxM365Scope` | `string` | No | `'https://manage.office.com/.default'` | Script-specific option. See the script help and examples before use. |
| `-UseExistingUsers` | `switch` | No |  | Use existing Entra users as agents instead of creating default users. |
| `-Auto` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-SkipBaseWizard` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-SkipAdxProvisioning` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-SkipRunbookDeploy` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-AddStorylineAgents` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ResetStorylinePasswords` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-SkipSmokeTest` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-SmokeTestAgent` | `string` | No | `'ana.rodriguez'` | Script-specific option. See the script help and examples before use. |
| `-KeepExistingAdxConfig` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-DryRun` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Install-LiveDemoMay272026ExpansionPack.ps1`

**Purpose:** Installs the May 27 2026 live demo expansion pack.

**Details:** Creates or reuses the Teams-backed SharePoint site LiveDemoMay272026, adds the demo personas, uploads the synthetic seed content, and stores optional Automation variables used by Invoke-AgentRunbook.ps1 to make Copilot search prompts aware of the live demo site. This script is intentionally separate from Step 4a so the core lab installer remains generic.

**Base command:**

```powershell
.\tools\Install-LiveDemoMay272026ExpansionPack.ps1
```

**Examples from script help:**

```powershell
.\tools\Install-LiveDemoMay272026ExpansionPack.ps1

.\tools\Install-LiveDemoMay272026ExpansionPack.ps1 -WhatIf

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-DisplayName` | `string` | No | `'LiveDemoMay272026'` | Script-specific option. See the script help and examples before use. |
| `-RootFolder` | `string` | No | `'Purview-Defender-SeedContent'` | Script-specific option. See the script help and examples before use. |
| `-ContentRoot` | `string` | No | `(Join-Path $PSScriptRoot '..\content-library\live-demo')` | Script-specific option. See the script help and examples before use. |
| `-SkipAutomationVariables` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Invoke-ActivityStoryMapRefresh.ps1`

**Purpose:** Forces a fresh Activity Story Map data refresh by running agent activity jobs.

**Details:** The Activity Story Map queries ADX live, so there is no separate cache to rebuild. This script starts agent activity runs and waits briefly for ADX ingestion so the map has fresh narrative data.

**Base command:**

```powershell
.\tools\Invoke-ActivityStoryMapRefresh.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agents` | `string[]` | No |  | One or more agent/persona selectors. Usually SAM names such as `priya.sharma`. |
| `-Parallel` | `switch` | No |  | Run supported operations concurrently. |
| `-ThrottleLimit` | `int` | No | `5` | Maximum number of concurrent operations when running in parallel. |
| `-ADXWaitMinutes` | `int` | No | `2` | Minutes to wait for ADX ingestion before querying results. |
| `-NoADXWait` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Invoke-BrowserAgentAuth.ps1`

**Purpose:** Captures a Microsoft 365 browser session for a BrowserAgent using Key Vault credentials.

**Details:** Reads the selected agent password from Key Vault, injects it into the Playwright auth setup process as an environment variable, and removes it from the current process after the command completes.

**Base command:**

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agent` | `string` | No | `'priya.sharma'` | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-BrowserAgentsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\BrowserAgents')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |

## `tools/Invoke-BrowserAgentDaily.ps1`

**Purpose:** Run real browser-based daily activity for one BrowserAgent.

**Base command:**

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa,copilot

.\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa -ExternalRecipient demo.recipient@example.com -SendEmail -Sensitive -Label General

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agent` | `string` | Yes |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-Services` | `string[]` | No | `@('owa','copilot')` | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-ExternalRecipient` | `string` | No | `''` | External mailbox target for OWA scenarios. Comma-separated values are supported. |
| `-SendEmail` | `switch` | No |  | Actually send OWA messages instead of only drafting/composing them. |
| `-Sensitive` | `switch` | No |  | Include synthetic sensitive business or personal data in generated activity. |
| `-Label` | `string` | No | `''` | Sensitivity label name to attempt to apply in supported browser/mail flows. |
| `-Azure` | `switch` | No |  | Run with Azure Playwright Workspaces instead of local Chromium where supported. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-BrowserAgentsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\BrowserAgents')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |

## `tools/Invoke-BrowserAgentScheduledRun.ps1`

**Purpose:** Run BrowserAgent daily activity using the schedules defined in config\agents.json.

**Details:** This is the scheduler-friendly entry point for BrowserAgents. By default it prints the execution plan only. Use -RunNow to execute immediately, or -DueOnly to execute only when the current local time is close to one of the configured schedules.

**Base command:**

```powershell
.\tools\Invoke-BrowserAgentScheduledRun.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-BrowserAgentScheduledRun.ps1

.\tools\Invoke-BrowserAgentScheduledRun.ps1 -RunNow -Agents priya.sharma -Services owa

.\tools\Invoke-BrowserAgentScheduledRun.ps1 -DueOnly -WindowMinutes 20 -ContinueOnFailure

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Agents` | `string[]` | No |  | One or more agent/persona selectors. Usually SAM names such as `priya.sharma`. |
| `-Services` | `string[]` | No | `@('owa','copilot')` | BrowserAgent service aliases to execute, such as `owa`, `copilot`, `internalai`, `deepseek`, `claude`, `grok`, `llama`, or `gemini`. |
| `-ExternalRecipient` | `string` | No | `'demo.recipient@example.com'` | External mailbox target for OWA scenarios. Comma-separated values are supported. |
| `-RunNow` | `switch` | No |  | Execute immediately instead of only printing a plan or waiting for due schedule. |
| `-DueOnly` | `switch` | No |  | Run only when the current time is close to a configured schedule. |
| `-WindowMinutes` | `int` | No | `20` | Schedule matching tolerance window in minutes. |
| `-SendEmail` | `switch` | No |  | Actually send OWA messages instead of only drafting/composing them. |
| `-Sensitive` | `switch` | No |  | Include synthetic sensitive business or personal data in generated activity. |
| `-Label` | `string` | No | `'General'` | Sensitivity label name to attempt to apply in supported browser/mail flows. |
| `-Azure` | `switch` | No |  | Run with Azure Playwright Workspaces instead of local Chromium where supported. |
| `-InitializeMissingSessions` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-RefreshAuth` | `switch` | No |  | Refresh browser session state by running interactive auth capture. |
| `-SkipPreflight` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ContinueOnFailure` | `switch` | No |  | Continue processing remaining agents/items after an error. |
| `-AdxWaitSeconds` | `int` | No | `30` | Seconds to wait for ADX ingestion before querying results. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |

## `tools/Invoke-BrowserAgentSmoke.ps1`

**Purpose:** Runs BrowserAgent smoke tests locally or in Azure Playwright Workspaces.

**Base command:**

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1

.\tools\Invoke-BrowserAgentSmoke.ps1 -Azure

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Azure` | `switch` | No |  | Run with Azure Playwright Workspaces instead of local Chromium where supported. |
| `-Daily` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-BrowserAgentsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\BrowserAgents')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |

## `tools/Invoke-EdgePersonaActivity.ps1`

**Purpose:** Prepares and launches Microsoft Edge persona activity for Endpoint DLP testing.

**Details:** Run this script inside a Windows 365 Cloud PC while signed in as the lab user. It creates synthetic sensitive files, copies sensitive text to the clipboard, and opens Microsoft Edge with a selected profile and test URLs. Microsoft Edge is the preferred browser for this pilot because Purview Endpoint DLP browser/domain restrictions are natively integrated with Edge. Chrome and Firefox require the Microsoft Purview extension. The script does not use Graph to label files. Its purpose is to drive browser and endpoint actions that Activity Explorer can attribute to the signed-in Windows user and device.

**Base command:**

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -UploadUrl https://copilot.microsoft.com

.\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -EdgeProfileDirectory "Profile 2" -PasteUrl https://chat.openai.com

.\tools\Invoke-EdgePersonaActivity.ps1 -Persona priya.sharma -UseIsolatedProfile -ProfileName Priya-Purview-Demo

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Persona` | `string` | No | `'priya.sharma'` | Script-specific option. See the script help and examples before use. |
| `-Department` | `string` | No | `'Data Science'` | Script-specific option. See the script help and examples before use. |
| `-EdgeProfileDirectory` | `string` | No | `'Default'` | Script-specific option. See the script help and examples before use. |
| `-UseIsolatedProfile` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-ProfileName` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-UploadUrl` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-PasteUrl` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-PrintUrl` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-SaveAsUrl` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-NetworkSharePath` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-OpenDownloadsFolder` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Invoke-EndpointPersonaActivity.ps1`

**Purpose:** Runs user-attributed endpoint activity from a Windows 365 Cloud PC.

**Details:** Execute this script inside the Cloud PC while signed in as the target lab user. It creates Office documents with synthetic sensitive data and performs local endpoint actions that Microsoft Purview Endpoint DLP can report in Activity Explorer when the device is onboarded and the user/device are in policy scope. This script is intentionally local-first. It does not use Graph to apply labels, because Graph label operations are service-attributed in Activity Explorer.

**Base command:**

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1
```

**Examples from script help:**

```powershell
.\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma

.\tools\Invoke-EndpointPersonaActivity.ps1 -Persona priya.sharma -NetworkSharePath \\server\share\PurviewLab -OpenBrowserPasteTest

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Persona` | `string` | No | `'priya.sharma'` | Script-specific option. See the script help and examples before use. |
| `-Department` | `string` | No | `'Data Science'` | Script-specific option. See the script help and examples before use. |
| `-NetworkSharePath` | `string` | No | `''` | Script-specific option. See the script help and examples before use. |
| `-CopyToOneDrive` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-OpenBrowserPasteTest` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-OpenManualPrintTest` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
| `-BrowserPasteUrl` | `string` | No | `'https://www.bing.com/search'` | Script-specific option. See the script help and examples before use. |

## `tools/List-AzureOpenAIModels.ps1`

**Purpose:** List chat-completion Azure OpenAI models available for the configured account.

**Base command:**

```powershell
.\tools\List-AzureOpenAIModels.ps1
```

**Examples from script help:**

```powershell
.\tools\List-AzureOpenAIModels.ps1

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |

## `tools/Publish-ActivityStoryMapAssets.ps1`

**Purpose:** Publishes Activity Story Map images to the existing static website storage.

**Details:** Copies images from Images\Characters, Images\Services, and Images\Branding into the Story Map web asset folder, generates a simple manifest, and uploads the web folder to the already configured Storage static website.

**Base command:**

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-ImagesRoot` | `string` | No | `(Join-Path $PSScriptRoot '..\Images')` | Script-specific option. See the script help and examples before use. |
| `-PurgeFrontDoor` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Publish-LiveDemoSeedContent.ps1`

**Purpose:** Uploads the 2026-05-27 live demo seed content pack to a SharePoint document library.

**Details:** Uses the current Azure CLI Microsoft Graph token to upload synthetic Defender/Purview demo documents from content-library/live-demo into a SharePoint drive. The files are synthetic lab data. Upload them several days before the live demo so Microsoft Search, Copilot, and Purview classification have time to index them.

**Base command:**

```powershell
.\tools\Publish-LiveDemoSeedContent.ps1
```

**Examples from script help:**

```powershell
.\tools\Publish-LiveDemoSeedContent.ps1 -SiteId "contoso.sharepoint.com,guid1,guid2"

.\tools\Publish-LiveDemoSeedContent.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/Demo"

.\tools\Publish-LiveDemoSeedContent.ps1 -Hostname "contoso.sharepoint.com" -SitePath "/sites/Demo"

.\tools\Publish-LiveDemoSeedContent.ps1 -SiteId "contoso.sharepoint.com,guid1,guid2" -RootFolder "LiveDemo/Purview"

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-SiteUrl` | `string` | No | `""` | Script-specific option. See the script help and examples before use. |
| `-SiteId` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-Hostname` | `string` | No | `""` | Script-specific option. See the script help and examples before use. |
| `-SitePath` | `string` | No | `""` | Script-specific option. See the script help and examples before use. |
| `-RootFolder` | `string` | No | `"LiveDemo/Purview-Defender-2026-05-27"` | Script-specific option. See the script help and examples before use. |
| `-ContentRoot` | `string` | No | `(Join-Path $PSScriptRoot "..\content-library\live-demo")` | Script-specific option. See the script help and examples before use. |

## `tools/Publish-RunbookOnly.ps1`

**Purpose:** Publish the local Invoke-AgentRunbook.ps1 to Azure Automation without rotating secrets.

**Details:** Uploads and publishes modules\Invoke-AgentRunbook.ps1 to the configured Automation Account. This is useful for code-only runbook fixes after Step 5 has already created Key Vault secrets and Automation variables. It also refreshes the non-secret AgentConfig Automation variable so ADX endpoint/client changes from Installation_definitions.json are picked up without rotating app or agent secrets.

**Base command:**

```powershell
.\tools\Publish-RunbookOnly.ps1
```

**Examples from script help:**

```powershell
.\tools\Publish-RunbookOnly.ps1

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |

## `tools/Reset-AgentPasswords.ps1`

**Purpose:** Reset configured agent passwords and synchronize their Key Vault secrets.

**Details:** Resets one, many, or all configured agent users to a generated/shared lab password, stores each per-agent password secret in Key Vault, and updates Automation variables that point the runbook to those secret names. Use this after an expansion or after an accidental shared-password overwrite to bring Entra ID, Key Vault, and Automation back into alignment.

**Base command:**

```powershell
.\tools\Reset-AgentPasswords.ps1
```

**Examples from script help:**

```powershell
.\tools\Reset-AgentPasswords.ps1 -All

.\tools\Reset-AgentPasswords.ps1 -Agent sofia.lopez -RevealPassword

.\tools\Reset-AgentPasswords.ps1 -All -AgentPassword 'LabPassword123!'

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |
| `-Agent` | `string[]` | No |  | Single agent/persona selector. Accepts SAM, UPN, or display name depending on the script. |
| `-All` | `switch` | No |  | Select all configured agents. |
| `-AgentPassword` | `string` | No |  | Script-specific option. See the script help and examples before use. |
| `-RevealPassword` | `switch` | No |  | Reveal sensitive values for lab troubleshooting. Use carefully. |
| `-SkipAutomationVariables` | `switch` | No |  | Script-specific option. See the script help and examples before use. |

## `tools/Set-AzureOpenAIName.ps1`

**Purpose:** Update the configured Azure OpenAI account name in config files.

**Details:** Azure OpenAI custom domains are globally unique. If a configured endpoint resolves to another tenant, update the account name before rerunning Step 4 and Step 5.

**Base command:**

```powershell
.\tools\Set-AzureOpenAIName.ps1
```

**Examples from script help:**

```powershell
.\tools\Set-AzureOpenAIName.ps1

.\tools\Set-AzureOpenAIName.ps1 -Name oai-claudia-lab

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-Name` | `string` | No |  | Resource or configuration name to create/update. |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |

## `tools/Test-BrowserAgentWorkspace.ps1`

**Purpose:** Validates the BrowserAgent Playwright Workspace resource.

**Details:** Checks Azure resource state, RBAC-relevant metadata, and prints the service endpoint required by Playwright. This does not run browser tests; use the BrowserAgents project for that once npm dependencies are installed.

**Base command:**

```powershell
.\tools\Test-BrowserAgentWorkspace.ps1
```

**Examples from script help:**

```powershell
.\tools\Test-BrowserAgentWorkspace.ps1

```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |

## `tools/Test-InstallationDefinitionsConsistency.ps1`

**Purpose:** Validate that installation-specific values are consistent across config files.

**Details:** Checks that config/Installation_definitions.json is present, builds the effective configuration, and reports common stale-value issues such as old ADX tenants, ingest-prefixed ADX URIs, or mismatched ADX blocks.

**Base command:**

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-ConfigPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\agents.json')` | Path to the main configuration file, usually `config/agents.json`. |
| `-InstallationDefinitionsPath` | `string` | No | `(Join-Path $PSScriptRoot '..\config\Installation_definitions.json')` | Path to installation definitions JSON used for resumable setup state. |

## `tools/Update-ActivityStoryMapCharacterProfiles.ps1`

**Purpose:** Builds the Activity Story Map character profile manifest.

**Details:** Parses Storyline\characters_presentations.md and enriches matching users with Microsoft Entra manager/direct report relationships through Microsoft Graph. The generated JSON is published with the static web portal.

**Base command:**

```powershell
.\tools\Update-ActivityStoryMapCharacterProfiles.ps1
```

**Parameters:**

| Parameter | Type | Mandatory | Default | Use |
| --- | --- | --- | --- | --- |
| `-StorylinePath` | `string` | No | `(Join-Path $PSScriptRoot '..\Storyline\characters_presentations.md')` | Script-specific option. See the script help and examples before use. |
| `-OutputPath` | `string` | No | `(Join-Path $PSScriptRoot '..\activity-story-map\web\character-profiles.json')` | Path where generated output, inputs, BrowserAgents project, or test results are located. |
| `-SkipGraph` | `switch` | No |  | Script-specific option. See the script help and examples before use. |
