# Common.ps1

## Purpose

Shared helper FACADE used by installer, modules, tests, and tools. `Common.ps1` itself is
a thin loader that dot-sources the three part files where the functions actually live:

- `Common.Core.ps1`: pure helpers -- passwords (`New-AALabPassword`), identity
  (`Get-AgentUpn`, `Get-AgentSecretName`), naming (`Get-KeyVaultName`, `Get-AAGlobalSuffix`),
  object utils (`Set-AAObjectProperty`).
- `Common.Config.ps1`: config/state -- tenant resolution (`Resolve-AATenantConfigPath`,
  `ConvertTo-AATenantConfigKey`), per-tenant state pairing
  (`Sync-AAInstallationDefinitionsWithTenant`), installation definitions
  (`Initialize/Save/Set-AAInstallationDefinition*`), atomic JSON writes (`Save-AAJsonAtomic`),
  effective config (`Get-AAEffectiveConfig`).
- `Common.Azure.ps1`: az CLI wrapper, Key Vault secret writes, Graph consent validation,
  public-network-access handling, connection cleanup. Also sets
  `AZURE_CORE_ONLY_SHOW_ERRORS=true` so az CLI warnings on stderr do not become
  terminating errors under `$ErrorActionPreference = 'Stop'`.

All four files ship together -- copying `Common.ps1` alone breaks every consumer
(the installer preflight and the update manifest both cover the part files).

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

Dot-sourced by `Install-ClaudIA.ps1` and by many supporting scripts.

## Variables and State

Reads and writes `config/Installation_definitions.json` through helper functions. It also helps merge values into effective config objects used by tools and tests.

