# Test-InstallationDefinitionsConsistency.ps1

## Purpose

Validates that `config/Installation_definitions.json` and `config/agents.json` agree on critical installation-specific values.

## Execution

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.

## Installer Integration

Not called by `Install-ClaudIA.ps1`. Use before publishing runbook code or troubleshooting ADX/Automation mismatches.

## Checks

Validates tenant ID, Key Vault name, OpenAI name, agent list, ADX values, ADX URI shape, and consistency between top-level ADX config and Step `4` ADX state.

