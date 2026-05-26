# Script Details and Considerations

This document complements the individual script documentation. Its purpose is to make dependencies, side effects, execution order, risks, and shared definitions clear without requiring a full PowerShell code read.

## Execution Model

The project has three script types:

- Orchestrators: run several steps and modify multiple components. Examples: `Install-ClaudIA.ps1`, `tools/Install-CleanAdxLab.ps1`.
- Deployment modules: called by the installer and provision a specific slice of the system. Examples: `modules/Deploy-Runbook.ps1`, `modules/Configure-CoreDLP.ps1`.
- Operational tools and tests: used after installation to validate, repair, or refresh data. Examples: `tests/Test-FullRun.ps1`, `tools/Get-RunbookStatus.ps1`, `tools/Reset-AgentPasswords.ps1`.

## Recommended Order

Full installation:

```powershell
.\Install-ClaudIA.ps1 -UseExistingUsers -Auto
```

Safe resume with existing state:

```powershell
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 4 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 5 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 6 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 7 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 8 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 9 -SkipPrerequisites
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 10 -SkipPrerequisites
```

Post-install validation:

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
.\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

## Shared External Dependencies

Most scripts assume:

- PowerShell 7 or compatible.
- Azure CLI authenticated with `az login`.
- Permissions in the configured subscription.
- Microsoft Graph permissions for users, groups, licenses, and app registration.
- ExchangeOnlineManagement for Purview, DLP, labels, and IRM.
- Access to Azure Resource Manager API.
- Access to Key Vault for setting/getting secrets.
- Access to ADX/Kusto for provisioning, ingestion, and query.
- MDCA portal URL and API token only when using optional Step `10`.

## State Files

- `config/agents.json`: editable source configuration.
- `config/Installation_definitions.json`: generated real installation state. Treat it as the operational reference after the first deployment.
- `logs/Install-ClaudIA-*.log`: installer execution history.
- `activity-story-map/web/images/manifest.json`: visual manifest for characters and services.

## Secret Model

The current pattern is:

- Key Vault stores real secret values.
- Automation variables store non-secret configuration and secret names.
- The runbook reads the secret name from Automation and resolves the value from Key Vault.
- Optional MDCA Cloud Discovery settings follow the same model: Step `10` stores the portal URL and API token in Key Vault and leaves only secret names plus non-secret stream settings in `config/agents.json`.

Do not manually edit an Automation password variable to store a plaintext secret. If credential drift occurs, use:

```powershell
.\tools\Reset-AgentPasswords.ps1 -All
```

## Script Matrix

| Script | Reads | Writes / Changes | Main Dependencies | Notes |
| --- | --- | --- | --- | --- |
| `Install-ClaudIA.ps1` | `agents.json`, `Installation_definitions.json` | Users, groups, licenses, app, Azure resources, definitions, logs | Azure CLI, Graph, Exchange, modules | Main entry point. Use `-UseInstallationDefinitions` for resume. |
| `Manage-Costs.ps1` | `agents.json` | Automation schedules, Fabric state | Azure CLI, ARM Cost API | Requires Cost Management Reader for live spend. |
| `modules/Common.ps1` | Config files | Installation definitions and shared state | Graph, Azure CLI | Dot-sourced helper, not a direct entry point. |
| `modules/Register-AgentApp.ps1` | Tenant/domain | App registration and permissions | Azure CLI, Graph | Step `3`; consent may need privileged admin. |
| `modules/Deploy-AzureInfra.ps1` | Effective config | RG, OpenAI, Automation, Key Vault, RBAC | Azure CLI, ARM REST | Step `4`; ADX is provisioned after it by a tool script. |
| `tools/Deploy-AdxTelemetry.ps1` | Installation definitions/effective ADX config | ADX cluster, database, table, mapping, Key Vault secret, definitions | Azure CLI, ARM, Kusto | Called after Step `4`; can be rerun idempotently. |
| `tools/Deploy-MdcaCloudDiscoveryConnector.ps1` | Effective config, MDCA URL/token prompt | Key Vault MDCA secrets, `agents.json` MDCA block | Azure CLI, Key Vault, MDCA API | Step `10`; optional pilot connector. |
| `modules/Provision-M365Collaboration.ps1` | Agents/departments | Teams, SharePoint, channels/folders, Automation variables | Graph, Teams/SharePoint APIs | Step `4a`; rerun if departments or agents change. |
| `modules/Provision-SensitivityLabels.ps1` | Config | Purview labels and label policy | ExchangeOnlineManagement/IPPS | Step `4b`; publishable labels only. |
| `modules/Provision-Fabric.ps1` | Config | Fabric capacity/workspace/lakehouse variables | Fabric/Azure APIs | Step `4c`; currently disabled. |
| `modules/Deploy-Runbook.ps1` | Config, runbook source | Key Vault secrets, Automation variables, runbook, schedules | Azure CLI, ARM, Key Vault | Step `5`; full refresh path for runtime. |
| `modules/Invoke-AgentRunbook.ps1` | Automation variables, Key Vault, config JSON | M365 activity, labels, ADX telemetry | Managed Identity, Graph, OpenAI, Key Vault, ADX | Runtime script in Azure Automation. |
| `modules/Configure-CoreDLP.ps1` | Config/domain, Purview SITs | DLP policies/rules | ExchangeOnlineManagement/IPPS | Step `6a`; category-based DLP. |
| `modules/Configure-DLP.ps1` | Config/domain, SITs | DSPM for AI policies | ExchangeOnlineManagement/IPPS | Step `6b`; AI exposure policies. |
| `modules/Configure-IRM.ps1` | Config/domain | IRM policy scaffolding | ExchangeOnlineManagement/IPPS | Step `6c`; some portal settings remain manual. |
| `modules/Deploy-Workbook.ps1` | ADX config | Azure Monitor Workbook | Azure CLI, ARM, ADX | Step `7`; requires ADX values. |
| `modules/Deploy-ActivityStoryMap.ps1` | Config, Story Map assets, ADX config | Storage static website, Function App, MI permissions, definitions | Azure CLI, ARM, ADX | Step `8`; deploys frontend/API. |
| `modules/Select-ExistingUsers.ps1` | Graph users | Returns selected agent objects | Graph token via Azure CLI | Used by Step `1` and preselection. |
| `prerequisites/Test-Prerequisites.ps1` | Config | None, validation only | Local tools, Azure CLI, modules | Step `0`; skipping is safe only after prior validation. |
| `tests/Test-SingleAgent.ps1` | Effective config, runbook content | Starts one Automation job | Azure CLI, ARM, ADX | Good first smoke test after Step `5`. |
| `tests/Test-FullRun.ps1` | Effective config | Starts many Automation jobs | Azure CLI, ARM, ADX | Supports parallel execution and ADX wait. |
| `tests/Test-AzureOpenAI.ps1` | Effective config | Sends test prompt | Azure CLI, Azure OpenAI | Use after Step `4`. |
| `tests/Test-AgentCredentials.ps1` | Effective config, Key Vault | Optional consent repair | Azure CLI, Graph, Key Vault | Use for auth/ROPC/secret drift. |
| `tools/Get-RunbookStatus.ps1` | Effective config | None, read-only | Azure CLI, ARM | Operational status view. |
| `tools/Publish-RunbookOnly.ps1` | Effective config, runbook source | Automation variable `AgentConfig`, runbook content | Azure CLI, ARM | Code-only update path. |
| `tools/Reset-AgentPasswords.ps1` | Effective config | Entra passwords, Key Vault secrets, Automation variables | Azure CLI, Graph, Key Vault, ARM | Repair path for credential drift. |
| `tools/Add-StorylineAgents.ps1` | `Storyline/profiles.md`, config | Agent config, definitions, optional secrets/variables | Graph, Key Vault, ARM | Expansion pack workflow. |
| `tools/Publish-ActivityStoryMapAssets.ps1` | `Images`, Story Map config | Web image assets, manifest, Storage blobs | Azure CLI, Storage | Use after changing visuals. |
| `tools/Invoke-ActivityStoryMapRefresh.ps1` | Effective config | Starts runbook jobs through `Test-FullRun` | Azure CLI, ARM, ADX | Data refresh path for the map. |
| `tools/List-AzureOpenAIModels.ps1` | Effective config | None, read-only | Azure CLI, Cognitive Services | Helps select model/version/quota. |
| `tools/Set-AzureOpenAIName.ps1` | Config and definitions | Updates OpenAI account name | Filesystem only | Use before rerunning Step `4` if name conflicts. |
| `tools/Test-InstallationDefinitionsConsistency.ps1` | Config and definitions | None, validation only | Filesystem | Use before runbook publish or troubleshooting. |
| `tools/Manage-ExternalRecipients.ps1` | `agents.json` | `externalRecipients` list | Filesystem | Maintains approved external mailboxes for BrowserAgent OWA scenarios. |
| `tools/Invoke-MdcaCloudDiscoveryIngestion.ps1` | `agents.json`, ADX, Key Vault | MDCA upload stream | Azure CLI, Key Vault, ADX, MDCA API | One-command ADX export plus MDCA upload after Step `10`. |
| `tools/Test-MdcaCloudDiscoveryApi.ps1` | `agents.json`, Key Vault, env vars | None | Azure CLI, Key Vault, MDCA API | Validates Step `10` connectivity without printing secrets. |
| `tools/Upload-MdcaCloudDiscoveryLog.ps1` | CEF/CSV log file, `agents.json`, Key Vault | MDCA upload stream | Azure CLI, Key Vault, MDCA API | Uploads exported ADX telemetry to MDCA Cloud Discovery. |
| `tools/Install-CleanAdxLab.ps1` | Config/definitions | Orchestrates installer, ADX, runbook, storyline, smoke test | Most project dependencies | Higher-level clean-lab flow. |

## Important Operational Considerations

- `-DryRun` and `-WhatIf` are not universal. They are useful previews, but some child scripts only support partial preview.
- `-UseInstallationDefinitions` should be used after the first successful install to avoid overwriting generated resource names.
- ADX provisioning can take several minutes. Table/query readiness can lag cluster/database creation.
- Entra ID user creation and license assignment can have replication delay.
- ROPC requires password auth and MFA exclusion. Conditional Access can still block runtime if exclusion is incomplete.
- Purview DLP/labels/IRM can take time to become visible or active in the portal.
- The Story Map has no separate cache. It reads ADX live through the Function API.
- `Publish-RunbookOnly.ps1` is the safest path for code-only runbook changes; Step `5` is the full runtime deployment path.
- `Reset-AgentPasswords.ps1` should be used when agent credentials drift. Avoid ad hoc password updates that bypass Key Vault.
- `Add-StorylineAgents.ps1` can update config and definitions; run collaboration provisioning again if new departments/channels are needed.

## Manual Portal Steps That May Remain

Some actions are intentionally printed as manual reminders because tenants differ:

- Conditional Access MFA exclusion for `grp-claudia-agent-mfa-exclusion`.
- Purview DSPM for AI enablement.
- IRM policy indicators for Generative AI apps.
- IRM Priority User Group validation.
- Any license assignment gaps when the tenant has insufficient eligible licenses.

## When To Use Which Script

- Need a full install: `Install-ClaudIA.ps1`.
- Need a clean ADX lab build with automation defaults: `tools/Install-CleanAdxLab.ps1`.
- Need to update runbook code only: `tools/Publish-RunbookOnly.ps1`.
- Need to test one user: `tests/Test-SingleAgent.ps1`.
- Need to generate demo data for all users: `tests/Test-FullRun.ps1`.
- Need Story Map data: `tools/Invoke-ActivityStoryMapRefresh.ps1`.
- Need Story Map images updated: `tools/Publish-ActivityStoryMapAssets.ps1`.
- Need password repair: `tools/Reset-AgentPasswords.ps1`.
- Need add characters/story expansion: `tools/Add-StorylineAgents.ps1`.
- Need check drift: `tools\Test-InstallationDefinitionsConsistency.ps1`.
- Need manage external mail targets: `tools\Manage-ExternalRecipients.ps1`.
- Need configure the MDCA Cloud Discovery pilot: `Install-ClaudIA.ps1 -Step 10`.
