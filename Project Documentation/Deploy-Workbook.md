# Deploy-Workbook.ps1

## Purpose

Deploys the Azure Monitor Workbook `ClaudIA Activity Monitor` backed by ADX queries.

## Execution

```powershell
.\modules\Deploy-Workbook.ps1 -Config $config
.\modules\Deploy-Workbook.ps1 -Config $config -WhatIf
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 7 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `WhatIf`: previews where supported.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `7`.

## Dependencies

Requires ADX to be enabled and configured in the effective config. The workbook expects ADX values such as `clusterName`, `databaseName`, and `tableName`.

