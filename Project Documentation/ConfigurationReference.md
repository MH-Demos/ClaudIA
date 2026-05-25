# Configuration Reference

This document defines the main configuration and state structures used by the scripts.

## `config/agents.json`

Editable source configuration for the lab.

Main sections:

- `tenant`: domain, subscription, location, country, and tenant ID.
- `infrastructure`: resource group, Automation Account, Azure OpenAI, model, TPM, Fabric, and Key Vault.
- `adx`: Azure Data Explorer configuration.
- `activityStoryMap`: Storage static website, Function API, and Story Map ADX source configuration.
- `schedules`: runbook schedules.
- `features`: behavior flags, such as user mode.
- `agents`: personas/agents and simulation attributes.

Relevant agent fields:

- `sam`: short identifier used by scripts.
- `userPrincipalName`: real user UPN.
- `displayName`: display name.
- `department`: operational department.
- `jobTitle`: job title.
- `wave`: demo or narrative wave.
- `workload`: primary workload for activity generation.
- `copilotLicense`: whether Copilot license assignment should be attempted.
- `existingUser`: whether the user comes from Entra ID.
- `workingHours`: activity window.
- `filesPerDay` and `emailsPerDay`: content volume controls.
- `topics`: prompt topics.
- `keyVaultSecretName`: associated Key Vault secret name.

## `config/Installation_definitions.json`

Generated state file. After the first installation, this file should be treated as the operational snapshot of the deployment.

It contains:

- `schemaVersion`, `runId`, `createdAt`, `updatedAt`.
- `sourceConfigPath` and `runLogPath`.
- Effective `tenant`.
- Effective `infrastructure`.
- Effective `agents`.
- `selectedUsers`.
- `environmentScan`.
- `steps`: detailed state per installer step.
- `deploymentResults`: step summary.
- `adx`: effective ADX block.

Recommended use:

- Do not delete it unless you intentionally want to restart installation state from scratch.
- Use `-UseInstallationDefinitions` to preserve real generated values.
- Validate it with `tools\Test-InstallationDefinitionsConsistency.ps1`.

## `config/email-threads.json`

Defines email conversation scenarios so the runbook can generate more realistic threads.

Usage:

- Its content is stored as the `AgentEmailThreads` Automation variable.
- The runbook uses it to create conversations with classification and DLP context.
- It should remain aligned with the active agents/personas.

## `Storyline/profiles.md`

Narrative source for the demo's human profiles. `tools/Add-StorylineAgents.ps1` consumes it to add agents/characters.

It defines name, UPN, role, location, and licenses when applicable.

## `Storyline/security_storyboard.md`

Describes business and security demo scenarios: Quarterly Business Review, HR Oversharing Risk, and Priya Discovers Too Much.

It is not consumed directly by the runbook; it guides prompts, content, assets, and expansion packs.

## `Storyline/implementation_review.md`

Gap analysis and narrative next-steps document. It identifies improvements such as OneDrive drafts, sharing links, calendar events, scenario IDs, and an optional content library.

## Automation Variables

Variables created or updated by Step `5` and related modules:

- `AgentTenantId`
- `AgentAppId`
- `AgentKeyVaultName`
- `AgentClientSecretName`
- `AgentConfig`
- `AgentEmailThreads`
- `AgentPwdSecret-<sam>`

Rule: Automation variables must not contain plaintext passwords or client secrets.

## Key Vault Secrets

Expected secrets:

- `agent-client-secret`: application secret.
- One secret per agent, for example `ana-rodriguez`.

Names are calculated by `Get-AgentSecretName` in `modules/Common.ps1`.

## ADX Event Shape

The current ADX table uses:

- `TimeGenerated: datetime`
- `Event: dynamic`

The dynamic payload can include properties such as:

- `Agent`
- `AgentUPN`
- `Department`
- `Workload`
- `Service`
- `ActivityType`
- `Action`
- `TargetName`
- `RecipientUPN`
- `SensitivityLabel`
- `DlpPolicies`
- `FileName`
- `Subject`
- `SearchQuery`

The Story Map and workbook depend on these events remaining consistent.

## Activity Story Map Config

`activityStoryMap` contains:

- `storageAccountName`
- `resourceGroup`
- `staticWebsiteUrl`
- `functionAppName`
- `apiBaseUrl`
- `launchUrl`
- `adxSource`

The Function requires these app settings:

- `ADX_QUERY_URI`
- `ADX_DATABASE`
- `ADX_TABLE`

## Naming Conventions

- Key Vault: `kv<base><hash>`
- Azure OpenAI: `oai-<base>-<hash>`
- ADX cluster: `adx-<domain><suffix>`
- ADX database/table/mapping: derived from the domain.
- Agent secret: normalized UPN local part, for example `ana.rodriguez` -> `ana-rodriguez`.

