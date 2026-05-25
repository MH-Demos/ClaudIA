# Common.ps1

## Purpose

Shared helper module used by installer, modules, tests, and tools. It centralizes UPN/secret naming, effective configuration loading, installation definitions, Graph consent validation, deployment result tracking, long-running notices, and connection cleanup.

## Execution

This script is dot-sourced by other scripts:

```powershell
. (Join-Path $PSScriptRoot 'modules\Common.ps1')
```

It is not normally executed directly.

## Key Functions

- `Get-AgentUpn`
- `Get-AgentSecretName`
- `Get-KeyVaultName`
- `Merge-AAInstallationDefinitionsIntoConfig`
- `Get-AAEffectiveConfig`
- `Get-AADataAgentGraphScopes`
- `Ensure-AADataAgentGraphConsent`
- `Set-AADeploymentResult`
- `Close-AAConnections`
- `Initialize-AAInstallationDefinitions`
- `Save-AAInstallationDefinitions`
- `Set-AAInstallationDefinition`
- `Set-AAInstallationStepDefinition`

## Installer Integration

Dot-sourced by `Install-AutonomousAgents.ps1` and by many supporting scripts.

## Variables and State

Reads and writes `config/Installation_definitions.json` through helper functions. It also helps merge values into effective config objects used by tools and tests.

