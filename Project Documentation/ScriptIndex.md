# Script Index

| Script | Purpose | Called by `Install-ClaudIA.ps1` |
| --- | --- | --- |
| `Install-ClaudIA.ps1` | Main deployment wizard | Main script |
| `Manage-Costs.ps1` | Cost status, estimates, and schedule/Fabric controls | No |
| `modules/Common.ps1` | Shared helpers for config, Key Vault names, installation definitions, and cleanup | Dot-sourced by installer/modules/tools |
| `modules/Configure-CoreDLP.ps1` | Category-based core DLP policies | Step `6a` |
| `modules/Configure-DLP.ps1` | DSPM for AI DLP policies | Step `6b` |
| `modules/Configure-IRM.ps1` | Insider Risk Management policy setup | Step `6c` |
| `modules/Deploy-ActivityStoryMap.ps1` | Static website and Function API for Activity Story Map | Step `8` |
| `modules/Deploy-AzureInfra.ps1` | Azure resource group, OpenAI, Automation, Key Vault | Step `4` |
| `modules/Deploy-Runbook.ps1` | Key Vault secrets, Automation variables, runbook, schedules | Step `5` |
| `modules/Deploy-Workbook.ps1` | ADX-backed Azure Monitor Workbook | Step `7` |
| `modules/Invoke-AgentRunbook.ps1` | Azure Automation runtime for agents | Deployed in Step `5` |
| `modules/Provision-Fabric.ps1` | Fabric workspace/capacity/lakehouse provisioning | Step `4c` |
| `modules/Provision-M365Collaboration.ps1` | Teams, SharePoint, folders/channels | Step `4a` |
| `modules/Provision-SensitivityLabels.ps1` | Purview sensitivity labels and label policy | Step `4b` |
| `modules/Register-AgentApp.ps1` | Entra app registration for data agent | Step `3` |
| `modules/Select-ExistingUsers.ps1` | Interactive existing-user picker | Step `1` / preselection |
| `prerequisites/Test-Prerequisites.ps1` | Local/cloud prerequisite validation | Step `0` |
| `tests/Test-AgentCredentials.ps1` | Credential and consent validation | No |
| `tests/Test-AzureOpenAI.ps1` | Azure OpenAI smoke test | No |
| `tests/Test-FullRun.ps1` | Starts runbook jobs for multiple agents | No |
| `tests/Test-SingleAgent.ps1` | Starts one agent runbook job | Mentioned after install |
| `tools/Add-StorylineAgents.ps1` | Add storyline personas | No |
| `tools/Deploy-AdxTelemetry.ps1` | Provision ADX telemetry resources | Step `4` after Azure infra |
| `tools/Get-RunbookStatus.ps1` | Inspect Automation runbook jobs | No |
| `tools/Install-CleanAdxLab.ps1` | End-to-end ADX lab orchestrator | No |
| `tools/Invoke-ActivityStoryMapRefresh.ps1` | Run agents to refresh ADX data for Story Map | No |
| `tools/List-AzureOpenAIModels.ps1` | List models and quota | No |
| `tools/Publish-ActivityStoryMapAssets.ps1` | Publish Story Map images/manifests | No |
| `tools/Publish-RunbookOnly.ps1` | Publish only runbook code/config | No |
| `tools/Reset-AgentPasswords.ps1` | Reset and synchronize agent passwords | No |
| `tools/Set-AzureOpenAIName.ps1` | Update OpenAI account name in config | No |
| `tools/Test-InstallationDefinitionsConsistency.ps1` | Validate effective configuration consistency | No |

## Supporting Documentation

| Document | Purpose |
| --- | --- |
| `ScriptDetails.md` | Cross-script dependencies, side effects, execution order, risks, and usage guidance. |
| `Standalone-Scripts-Reference.md` | Direct-run script reference with all discovered parameters and usage notes. |
| `ConfigurationReference.md` | Definitions for config files, Automation variables, Key Vault secrets, ADX events, and Story Map settings. |
| `OperationalConsiderations.md` | Safety, idempotency, timing, troubleshooting, cost, and cleanup considerations. |
| `Glossary.md` | Terms and abbreviations used across the project. |
