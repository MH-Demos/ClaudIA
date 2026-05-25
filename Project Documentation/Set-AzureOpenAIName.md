# Set-AzureOpenAIName.ps1

## Purpose

Updates the Azure OpenAI account name in `config/agents.json` and `config/Installation_definitions.json`.

## Execution

```powershell
.\tools\Set-AzureOpenAIName.ps1
.\tools\Set-AzureOpenAIName.ps1 -Name oai-claudia-lab
```

## Parameters

- `Name`: Azure OpenAI account name. If omitted, a deterministic default is generated.
- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.

## Installer Integration

Not called by `Install-ClaudIA.ps1`. Use before rerunning Step `4` and Step `5` if the configured Azure OpenAI name conflicts or points to another tenant.

