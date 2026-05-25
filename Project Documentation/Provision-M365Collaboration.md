# Provision-M365Collaboration.ps1

## Purpose

Creates or connects to Microsoft 365 collaboration assets for the lab, including Teams/SharePoint structures, department spaces, and related Automation variables.

## Execution

```powershell
.\modules\Provision-M365Collaboration.ps1 -Config $config -Mode create
.\modules\Provision-M365Collaboration.ps1 -Config $config -Mode existing
```

Normally run by:

```powershell
.\Install-AutonomousAgents.ps1 -Step 4 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Mode`: `create` or `existing`.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `4a`.

## Current Configuration

- Team: `CorpLab - Departments`
- Departments: `HR`, `Finance`, `Legal`, `Engineering`, `Sales`

