# Test-AzureOpenAI.ps1

## Purpose

Runs a smoke test against the configured Azure OpenAI deployment.

## Execution

```powershell
.\tests\Test-AzureOpenAI.ps1
.\tests\Test-AzureOpenAI.ps1 -Prompt "Generate a short compliance test message."
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `Prompt`: prompt to send to Azure OpenAI.

## Installer Integration

Not called by `Install-ClaudIA.ps1`. Use after Step `4` or after changing Azure OpenAI configuration.

## Alternatives

Use `tools\List-AzureOpenAIModels.ps1` to inspect available models and quota before troubleshooting a failed prompt.

