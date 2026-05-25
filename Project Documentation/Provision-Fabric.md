# Provision-Fabric.ps1

## Purpose

Provisions or connects to Fabric resources used by the lab when Fabric is enabled.

## Execution

```powershell
.\modules\Provision-Fabric.ps1 -Config $config -Mode create
.\modules\Provision-Fabric.ps1 -Config $config -Mode existing
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Mode`: create or reuse existing Fabric resources.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `4c`.

## Current Configuration

Fabric is currently disabled with `fabricEnabled=false`, so Step `4c` is skipped.

