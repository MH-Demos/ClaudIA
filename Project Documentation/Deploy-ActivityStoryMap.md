# Deploy-ActivityStoryMap.ps1

## Purpose

Deploys the Activity Story Map frontend and API. The frontend is an Azure Storage static website. The API is an Azure Function with managed identity that queries ADX.

## Execution

```powershell
.\modules\Deploy-ActivityStoryMap.ps1 -Config $config
.\modules\Deploy-ActivityStoryMap.ps1 -Config $config -WhatIf
```

Normally run by:

```powershell
.\Install-AutonomousAgents.ps1 -Step 8 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `WhatIf`: previews where supported.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `8`.

## Current Output

- Static website: `https://stclaudiamap.z22.web.core.windows.net/`
- API: `https://func-claudia-story.azurewebsites.net`
- Launch URL: `https://stclaudiamap.z22.web.core.windows.net/?api=https://func-claudia-story.azurewebsites.net`

