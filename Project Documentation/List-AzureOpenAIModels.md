# List-AzureOpenAIModels.ps1

## Purpose

Lists Azure OpenAI models and quota for the configured Azure OpenAI account and location.

## Execution

```powershell
.\tools\List-AzureOpenAIModels.ps1
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.

## Installer Integration

Not called by `Install-ClaudIA.ps1`.

## Alternatives

Use Azure Portal or Azure CLI directly for account/model inspection. This script is tuned to the lab's effective configuration.

