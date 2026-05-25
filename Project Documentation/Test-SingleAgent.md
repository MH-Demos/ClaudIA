# Test-SingleAgent.ps1

## Purpose

Starts one Azure Automation runbook job for a selected agent and validates that the configured Automation Account/runbook can execute it.

## Execution

```powershell
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
```

## Parameters

- `Agent`: target agent SAM/UPN. Mandatory.
- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.

## Installer Integration

Not called by `Install-ClaudIA.ps1`, but printed as a recommended post-install command.

## Alternatives

Use `tests\Test-FullRun.ps1` for multiple agents.

