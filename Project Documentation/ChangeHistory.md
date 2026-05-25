# Change History

This file documents the changes made in `ClaudIA` compared with the original project located at `C:\MyDev\Nabil\ClaudIA-master`.

The comparison was performed by inspecting files, scripts, generated configuration, and local logs because `git` is not available in this environment.

## Executive Summary

The project evolved from a basic autonomous-agent installer with simple monitoring into a broader Microsoft 365 and Purview demo lab architecture:

- The telemetry approach was migrated from Log Analytics to Azure Data Explorer (ADX).
- Secret handling was moved to Azure Key Vault, leaving Automation variables for non-secret configuration and secret names.
- `config/Installation_definitions.json` was added as the durable source of truth for the deployed installation.
- Activity Story Map was added as a web experience to visualize agent activity as a narrative from ADX.
- Storytelling was added through profiles, storyboard files, characters, images, and agent expansion packs.
- Operational tests were added, especially `tests/Test-FullRun.ps1`, to run multiple agents and validate ADX ingestion.
- The Purview layer was expanded with sensitivity labels, category-based DLP, DSPM for AI, and IRM.

## Architecture Change: Log Analytics to ADX

The original project contained Log Analytics references as the primary monitoring backend. In this version, operational agent telemetry was migrated to Azure Data Explorer.

Main changes:

- `modules/Deploy-AzureInfra.ps1` no longer deploys custom Log Analytics telemetry as the lab's primary telemetry backend.
- Installer logs explicitly show the change: `Skipping Log Analytics custom telemetry; ADX telemetry is enabled`.
- `tools/Deploy-AdxTelemetry.ps1` was added to create and configure ADX.
- `modules/Invoke-AgentRunbook.ps1` now ingests structured events into ADX.
- `modules/Deploy-Workbook.ps1` was redirected to KQL queries over ADX.
- `modules/Deploy-ActivityStoryMap.ps1` and the `activity-story-map` web application read activity from ADX, not from Log Analytics.

Current ADX resources:

- Cluster: `adx-claudia-lab`
- Database: `ADX-CLAUDIA`
- Table: `CLAUDIA_AgentActivity`
- Mapping: `CLAUDIA_AgentActivity_mapping`
- Retention: `365` days
- SKU: `Dev(No SLA)_Standard_E2a_v4`
- Query/Ingest URI: `https://adx-claudia-lab.westus.kusto.windows.net`

Impact:

- ADX is now the activity-event repository for the agents.
- Validations and dashboards use KQL against ADX.
- `Test-FullRun.ps1` can wait for ADX ingestion with `-ADXWaitMinutes`.
- `Invoke-ActivityStoryMapRefresh.ps1` runs agents to populate ADX before opening the map.

Note: some legacy documentation under `docs/` and `DISCLAIMER.md` still mentions Log Analytics. Those references are historical or pending documentation cleanup; the active script-driven architecture uses ADX.

## Security Change: Credentials in Key Vault

The current version replaces direct password/secret storage in Automation variables with a Key Vault-based pattern.

Main changes:

- `modules/Deploy-Runbook.ps1` stores real secrets in Key Vault.
- Automation variables store secret names and non-secret configuration.
- `modules/Invoke-AgentRunbook.ps1` resolves secrets from Key Vault at runtime.
- `tools/Reset-AgentPasswords.ps1` synchronizes Entra ID, Key Vault, and Automation variables.
- `tests/Test-AgentCredentials.ps1` validates secrets, consent, and token acquisition.

Current Key Vault:

- Vault: `kv-claudia-lab`
- App secret: `agent-client-secret`
- Agent secrets: `ana-rodriguez`, `carlos-delgado`, `david-chen`, `james-wilson`, `marcus-olsson`, `alexander-meyer`, `diego-martinez`, `emily-johnson`, `laura-gomez`, `priya-sharma`, `miguel-santos`, `sofia-lopez`

Relevant Automation variables:

- `AgentTenantId`
- `AgentAppId`
- `AgentKeyVaultName`
- `AgentClientSecretName`
- `AgentConfig`
- `AgentEmailThreads`
- `AgentPwdSecret-<sam>`

Impact:

- Secrets no longer live as plaintext values in Automation.
- Existing secrets can be preserved when runbook code is republished.
- `Publish-RunbookOnly.ps1` can update the runbook without rotating credentials.
- `Reset-AgentPasswords.ps1` is the dedicated tool for repairing or rotating credentials.

## Installation Definitions as Durable State

`config/Installation_definitions.json` was added to store the real deployment state.

It stores:

- Tenant, subscription, location, and domain.
- Resource group, Automation Account, OpenAI account, and Key Vault.
- Selected agents and their `keyVaultSecretName` values.
- Execution state for each installer step.
- ADX configuration.
- Activity Story Map URLs.
- Active run log path.
- Deployment results.

Related scripts:

- `modules/Common.ps1`
- `tools/Test-InstallationDefinitionsConsistency.ps1`
- `tools/Set-AzureOpenAIName.ps1`
- `tools/Deploy-AdxTelemetry.ps1`
- `tools/Publish-RunbookOnly.ps1`
- `tools/Install-CleanAdxLab.ps1`

Impact:

- The installer can resume with `-UseInstallationDefinitions`.
- Real generated resource names are preserved.
- The risk of mixing base configuration values with generated installation values is reduced.

## Main Installer Changes

`Install-AutonomousAgents.ps1` was significantly expanded.

New parameters or capabilities:

- `-UseInstallationDefinitions`
- `-Auto`
- `-AgentPassword`
- `-UseExistingUsers`
- `-Step` with logical substep support.
- `-DryRun`

Flow changes:

- Step `0`: connection reset and prerequisite validation.
- Step `1`: create or select users.
- Step `2`: license assignment and MFA exclusion group.
- Step `3`: `app-dataagent` app registration.
- Step `4`: Azure infrastructure and Key Vault.
- After Step `4`: ADX provisioning through `tools/Deploy-AdxTelemetry.ps1`.
- Step `4a`: Microsoft 365 collaboration.
- Step `4b`: sensitivity labels.
- Step `4c`: optional Fabric provisioning.
- Step `5`: Key Vault secrets, Automation variables, runbook, and schedules.
- Step `6a`: core DLP policies.
- Step `6b`: DSPM for AI policies.
- Step `6c`: IRM policies.
- Step `7`: ADX workbook.
- Step `8`: Activity Story Map.

The installer also prints post-install commands for:

- `tests/Test-SingleAgent.ps1`
- `tests/Test-FullRun.ps1`
- `tools/Get-RunbookStatus.ps1`
- Rerunning Step `7` and Step `8`.

## Activity Story Map

A complete web experience was added to visualize agent activity as a story.

Added structure:

- `activity-story-map/web/index.html`
- `activity-story-map/web/app.js`
- `activity-story-map/web/styles.css`
- `activity-story-map/api/host.json`
- `activity-story-map/api/ActivityGraph/function.json`
- `activity-story-map/api/ActivityGraph/index.js`
- `activity-story-map/web/images/manifest.json`
- `activity-story-map/web/images/characters`
- `activity-story-map/web/images/services`

Architecture:

- Azure Storage static website hosts the frontend.
- Azure Function exposes the `/api/graph` API.
- The Function uses Managed Identity.
- The Managed Identity receives ADX Viewer permission.
- The frontend calls the API and displays nodes, events, characters, and services.
- ADX is the live activity source.

Current resources:

- Static website: `https://stclaudiamap.z22.web.core.windows.net/`
- API base: `https://func-claudia-story.azurewebsites.net`
- Launch URL: `https://stclaudiamap.z22.web.core.windows.net/?api=https://func-claudia-story.azurewebsites.net`
- Function App: `func-claudia-story`

Related scripts:

- `modules/Deploy-ActivityStoryMap.ps1`: deploys the Storage static website and Function App.
- `tools/Publish-ActivityStoryMapAssets.ps1`: publishes images and manifests.
- `tools/Invoke-ActivityStoryMapRefresh.ps1`: runs agents to refresh ADX data.
- `tests/Test-FullRun.ps1`: generates recent activity for the map.

## Images, Characters, and Personification

Visual assets were added so activity is no longer anonymous or generic.

Added folders:

- `Images/Characters`
- `Images/Services`
- `activity-story-map/web/images/characters`
- `activity-story-map/web/images/services`

Characters with images:

- Alexander Meyer
- Ana Rodriguez
- Carlos Delgado
- David Chen
- Diego Martinez
- Emily Johnson
- James Wilson
- Laura Gomez
- Marcus Olsson
- Miguel Santos
- Priya Sharma
- Sofia Lopez

Services with images:

- Copilot
- Edge
- Fabric
- Mail
- OneDrive
- SharePoint
- Teams
- Viva

Impact:

- The Story Map can show recognizable actors.
- The demo communicates who did what, in which service, and with what possible security impact.
- Agents are no longer only JSON entries; they have narrative identity.

## Storytelling and Storyline

The `Storyline/` folder was added to give narrative meaning to generated activity.

Added files:

- `Storyline/profiles.md`
- `Storyline/security_storyboard.md`
- `Storyline/implementation_review.md`

Changes in approach:

- Agents were aligned with real demo business profiles.
- Roles, locations, and licenses were documented.
- Business and security scenarios were defined:
  - Quarterly Business Review
  - HR Oversharing Risk
  - Priya Discovers Too Much
  - Customer/Security/Legal escalation as a recommended storyline
- Alignment between scenarios, departments, prompts, sensitive data, and workloads was reviewed.

Runbook impact:

- `Invoke-AgentRunbook.ps1` generates more contextual department content.
- `config/email-threads.json` contains more realistic multi-turn conversations.
- Prompts include security, DLP, collaboration, and workplace context.
- Activity sent to Teams and ADX can be read as a narrative sequence, not only isolated events.

## Story Expansion Packs

`tools/Add-StorylineAgents.ps1` was added to incorporate new agents/characters without replacing the original cast.

Script capabilities:

- Reads profiles from `Storyline/profiles.md`.
- Allows profile filtering with `-Search`.
- Allows automatic addition with `-AutoFromProfiles`.
- Resolves default department and workload.
- Can reset passwords.
- Can store secrets in Key Vault.
- Can update Automation variables.
- Synchronizes `config/agents.json` and `config/Installation_definitions.json`.

Relevant commands:

```powershell
.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles
.\tools\Add-StorylineAgents.ps1 -Search sofia -StoreInKeyVault -UpdateAutomationVariables
.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles -ResetPassword -RevealPassword
```

Impact:

- A narrative expansion pack can be created by adding characters.
- Expansion does not overwrite the original agents.
- The lab can grow in story waves.
- Users such as Miguel Santos and Sofia Lopez can be added with consistent secrets and variables.

## Test-FullRun and New Test Strategy

`tests/Test-FullRun.ps1` was added and required more explicit documentation.

Capabilities:

- Runs the runbook for all configured agents.
- Allows subset selection with `-Agents`.
- Supports sequential or parallel execution.
- Controls concurrency with `-ThrottleLimit`.
- Monitors Azure Automation jobs.
- Retrieves status, output, and streams.
- Can wait for ADX ingestion with `-ADXWaitMinutes`.
- Can skip ADX wait with `-NoADXWait`.

Examples:

```powershell
.\tests\Test-FullRun.ps1
.\tests\Test-FullRun.ps1 -Agents ana.rodriguez,carlos.delgado -ADXWaitMinutes 2
.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5 -NoADXWait
```

Other added or expanded tests:

- `tests/Test-SingleAgent.ps1`: runs a single target agent.
- `tests/Test-AzureOpenAI.ps1`: Azure OpenAI smoke test.
- `tests/Test-AgentCredentials.ps1`: validates secrets, consent, passwords, and tokens.

Complementary tool:

- `tools/Get-RunbookStatus.ps1`: inspects recent executions, streams, output, and schedules.

## Runbook Functional Changes

`modules/Invoke-AgentRunbook.ps1` was expanded to support the new architecture and narrative model.

Main changes:

- Reads configuration from Automation variables.
- Resolves secrets from Key Vault.
- Authenticates each agent through ROPC.
- Uses Azure OpenAI to generate contextual content.
- Generates files by department and workload.
- Publishes to SharePoint/OneDrive.
- Sends emails and conversations with DLP context.
- Posts activity to Teams.
- Applies sensitivity labels through Graph.
- Scans for unlabeled files.
- Ingests events into ADX.
- Includes functions to build structured events: agent, department, workload, sensitivity, service, file, label, and policy context.
- Maintains label rules by department and file type.

## Sensitivity Labels, DLP, DSPM, and IRM

The Purview layer was strengthened.

Sensitivity labels:

- `modules/Provision-SensitivityLabels.ps1` creates `General`, `Confidential`, `Conf-HR`, `Conf-Finance`, and `Highly Confidential`.
- It publishes only usable labels and avoids publishing parent label groups.

Core DLP:

- `modules/Configure-CoreDLP.ps1` was added.
- It creates separate policies for Exchange, SharePoint, OneDrive, Teams, Endpoint, and Copilot.
- It groups rules by sensitive information categories:
  - Payment Card Data
  - Identity and Personal Data
  - Sensitive Personal and Health Data
  - Financial and Tax Information
  - Credentials and Access Secrets
  - Legal and Corporate Sensitive Information
  - Intellectual Property and Technical Information
- It creates internal and outbound rules where applicable.
- It adds Copilot rules based on `Conf-HR` and `Conf-Finance` labels.

DSPM for AI:

- `modules/Configure-DLP.ps1` configures DSPM policies focused on AI/Copilot.
- Current policies:
  - `DLP-CopilotStudio-PII-Monitor`
  - `DSPM-AI-Labels-Restrict`
  - `DSPM-AI-AgentActivity-Audit`

IRM:

- `modules/Configure-IRM.ps1` adds:
  - `IRM-DataLeaks-Lab`
  - `IRM-RiskyAI-Lab`
- It includes portal instructions for AI indicators and priority user groups.

## Microsoft 365 Collaboration and Fabric

`modules/Provision-M365Collaboration.ps1` was adjusted to support existing agents and the departmental structure.

Current state:

- Team: `CorpLab - Departments`
- Departments: `HR`, `Finance`, `Legal`, `Engineering`, `Sales`
- All selected agents are added to collaboration spaces as appropriate.

Fabric:

- `modules/Provision-Fabric.ps1` remains available as optional provisioning.
- The current configuration has `fabricEnabled=false`.
- The installer keeps Step `4c` for environments that require a Fabric workspace/lakehouse.

## New Operational Tools

The `tools/` folder was added with operational and maintenance scripts:

- `Add-StorylineAgents.ps1`: character/story expansion pack.
- `Deploy-AdxTelemetry.ps1`: ADX provisioning.
- `Get-RunbookStatus.ps1`: Automation job status.
- `Install-CleanAdxLab.ps1`: end-to-end orchestrator for a clean ADX lab.
- `Invoke-ActivityStoryMapRefresh.ps1`: refreshes Story Map data by running agents.
- `List-AzureOpenAIModels.ps1`: available models and quotas.
- `Publish-ActivityStoryMapAssets.ps1`: publishes Story Map images/manifests.
- `Publish-RunbookOnly.ps1`: republishes the runbook without rotating secrets.
- `Reset-AgentPasswords.ps1`: synchronizes passwords across Entra ID, Key Vault, and Automation.
- `Set-AzureOpenAIName.ps1`: changes Azure OpenAI name in config/definitions.
- `Test-InstallationDefinitionsConsistency.ps1`: validates effective configuration consistency.

## Configuration Changes

`config/agents.json`:

- Expanded to 12 effective agents.
- Includes ADX configuration.
- Includes `activityStoryMap` configuration.
- Retains tenant, infrastructure, features, schedules, and personas.
- Adds storyline agents such as Miguel Santos and Sofia Lopez.

`config/email-threads.json`:

- Expanded with richer conversations.
- Includes sensitive business context.
- Aligns email content with DLP, security, sales, HR, legal, and collaboration scenarios.

`config/locales`:

- Keeps `US`, `UK`, `FR`, and `DE` locales.
- The installer can load personas by country/locale.

## Local Documentation Changes

Added or updated documents:

- `docs/installation-definitions.md`
- `docs/testing-adx.md`
- `Storyline/profiles.md`
- `Storyline/security_storyboard.md`
- `Storyline/implementation_review.md`
- `Project Documentation/*`

Recommended pending cleanup:

- Update inherited Log Analytics references in `docs/` and `DISCLAIMER.md`.
- Align cost documentation with ADX and Key Vault as the active architecture.

## Important Modified Files

- `Install-AutonomousAgents.ps1`: expanded main orchestration.
- `Manage-Costs.ps1`: cost controls.
- `modules/Common.ps1`: configuration/definitions/secrets helper layer.
- `modules/Deploy-AzureInfra.ps1`: Azure infrastructure, OpenAI, Automation, Key Vault, and providers.
- `modules/Deploy-Runbook.ps1`: Key Vault secrets and Automation variables.
- `modules/Invoke-AgentRunbook.ps1`: runtime, labels, Graph, ADX, and storytelling.
- `modules/Deploy-Workbook.ps1`: ADX workbook.
- `modules/Deploy-ActivityStoryMap.ps1`: Story Map web/API deployment.
- `modules/Configure-CoreDLP.ps1`: category-based DLP.
- `modules/Configure-DLP.ps1`: DSPM for AI.
- `modules/Configure-IRM.ps1`: IRM.
- `modules/Provision-M365Collaboration.ps1`: Microsoft 365 collaboration.
- `modules/Provision-SensitivityLabels.ps1`: labels and policy.
- `modules/Register-AgentApp.ps1`: app registration.
- `modules/Select-ExistingUsers.ps1`: existing user selection.
- `prerequisites/Test-Prerequisites.ps1`: updated prerequisites.
- `tests/Test-FullRun.ps1`: multi-agent/parallel execution and ADX wait.
- `tests/Test-SingleAgent.ps1`: individual agent validation.

## Current Result

The `ClaudIA` version is now a demo lab with:

- Personified agents.
- Business and security storylines.
- Realistic activity generation.
- Secrets in Key Vault.
- Durable state in `Installation_definitions.json`.
- Telemetry in ADX.
- ADX workbook.
- Activity Story Map web application.
- Expansion packs through `Add-StorylineAgents.ps1`.
- Operational tests to run agents and validate ingestion.

