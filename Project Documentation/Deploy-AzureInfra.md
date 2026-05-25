# Deploy-AzureInfra.ps1

## Purpose

Deploys Azure infrastructure: resource group, Azure OpenAI, Azure Automation, Key Vault, providers, model deployments, and role assignments needed for the runbook.

## Execution

```powershell
.\modules\Deploy-AzureInfra.ps1 -Config $config
.\modules\Deploy-AzureInfra.ps1 -Config $config -Auto
```

Normally run by:

```powershell
.\Install-AutonomousAgents.ps1 -Step 4 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Auto`: uses automatic choices where the module prompts, especially around model selection.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `4`. After this module, the installer calls `tools/Deploy-AdxTelemetry.ps1`.

## Current Configuration

- Resource group: `rg-claudia-lab`
- Azure OpenAI: `oai-claudia-lab`
- Automation Account: `aa-claudia-lab`
- Key Vault: `kv-claudia-lab`
- Model: `gpt-4.1-mini`

## Alternatives

Use `tools\List-AzureOpenAIModels.ps1` before or after deployment to inspect available models and quota.

