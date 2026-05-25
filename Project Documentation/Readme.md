# ClaudIA - Project Summary

This project deploys a Microsoft 365 and Microsoft Purview lab that uses autonomous AI agents to generate realistic corporate activity for data protection, DLP, Insider Risk Management, DSPM for AI, sensitivity labeling, audit, and monitoring demonstrations.

The main entry point is `Install-ClaudIA.ps1`. It reads `config/agents.json`, optionally merges installation-specific state from `config/Installation_definitions.json`, provisions Microsoft 365/Azure resources, deploys the Azure Automation runbook `modules/Invoke-AgentRunbook.ps1`, and configures monitoring assets such as ADX telemetry, Azure Monitor Workbook, and the Activity Story Map.

## Current Environment Snapshot

- Tenant domain: `contoso.example`
- Tenant ID: `00000000-0000-0000-0000-000000000000`
- Subscription ID: `11111111-1111-1111-1111-111111111111`
- Location: `westus`
- Resource group: `rg-claudia-lab`
- Automation Account: `aa-claudia-lab`
- Key Vault: `kv-claudia-lab`
- Azure OpenAI account: `oai-claudia-lab`
- Chat model: `gpt-4.1-mini`, version `2025-04-14`, TPM `30`
- Fabric: disabled in the current configuration
- ADX cluster: `adx-claudia-lab`
- ADX database: `ADX-CLAUDIA`
- ADX table: `CLAUDIA_Activity`
- Activity Story Map URL: `https://stclaudiamap.z22.web.core.windows.net/?api=https://func-claudia-story.azurewebsites.net`

## Minimum Execution Commands

Run from:

```powershell
cd C:\MyDev\Nabil\ClaudIA-master\ClaudIA
```

Validate prerequisites:

```powershell
.\prerequisites\Test-Prerequisites.ps1
```

Run full interactive deployment:

```powershell
.\Install-ClaudIA.ps1
```

Run full deployment using existing users and automation-friendly defaults:

```powershell
.\Install-ClaudIA.ps1 -UseExistingUsers -Auto
```

Resume or run only one installer step:

```powershell
.\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites -UseInstallationDefinitions
.\Install-ClaudIA.ps1 -Step 5 -SkipPrerequisites -UseInstallationDefinitions
.\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites -UseInstallationDefinitions
```

Publish only runbook code after a local runbook change:

```powershell
.\tools\Publish-RunbookOnly.ps1
```

Check recent runbook jobs:

```powershell
.\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams
```

Run one agent manually:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
```

Run all configured agents and wait for ADX ingestion:

```powershell
.\tests\Test-FullRun.ps1 -ADXWaitMinutes 2
```

Refresh Activity Story Map data:

```powershell
.\tools\Invoke-ActivityStoryMapRefresh.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

## Documentation Map

- `Architecture.md`: components, current configuration, and where variables are stored.
- `ChangeHistory.md`: changes made compared with the original project folder.
- `ScriptIndex.md`: quick index of all scripts and whether they are called by `Install-ClaudIA.ps1`.
- `Standalone-Scripts-Reference.md`: direct-run script reference with base commands and parameter tables.
- `ScriptDetails.md`: dependencies, side effects, order, risks, and a matrix for all scripts.
- `ConfigurationReference.md`: definitions for config files, Automation variables, Key Vault secrets, ADX events, and Story Map settings.
- `OperationalConsiderations.md`: safety, idempotency, timing, troubleshooting, cost, and cleanup guidance.
- `Glossary.md`: key terms and abbreviations.
- One Markdown file per `.ps1` script with purpose, execution, parameters, alternatives, and installer step integration.
- `Operations.md`: recommended operational workflows after deployment.
