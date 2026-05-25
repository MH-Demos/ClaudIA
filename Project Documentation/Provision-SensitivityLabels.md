# Provision-SensitivityLabels.ps1

## Purpose

Creates and publishes the Purview sensitivity labels used by the runbook for file classification.

## Execution

```powershell
.\modules\Provision-SensitivityLabels.ps1 -Config $config
.\modules\Provision-SensitivityLabels.ps1 -Config $config -SkipPublish
```

Normally run by:

```powershell
.\Install-AutonomousAgents.ps1 -Step 4 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `SkipPublish`: creates labels but skips label policy publication.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `4b`.

## Labels

- `General`
- `Confidential`
- `Confidential/Conf-HR`
- `Confidential/Conf-Finance`
- `Highly Confidential/All Employees`

The script avoids publishing parent label groups directly and publishes only usable labels.

