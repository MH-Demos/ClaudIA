# Configure-IRM.ps1

## Purpose

Deploys Insider Risk Management policy scaffolding for the lab. It uses DLP policy signals and scopes risk monitoring to autonomous agent users.
The script now also attempts to apply the lab policies to all users and enable the main download, exfiltration, deletion, obfuscation, and label downgrade/removal indicators when the installed Security & Compliance PowerShell module exposes those settings.

## Execution

```powershell
.\modules\Configure-IRM.ps1 -Config $config -Domain contoso.example
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Domain`: tenant domain.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `6c`.

## Policies

- `IRM-DataLeaks-Lab`
- `IRM-RiskyAI-Lab`

## Policy Scope and Indicators

After creating or finding each policy, the script tries to set the user scope to all users. If the current module version does not expose the required scope parameter, the script prints the exact portal follow-up: edit each policy and choose **Users and groups > Include all users and groups**.

For indicators, the script enables supported switches such as SharePoint/OneDrive download, external email, cumulative exfiltration, label downgrade/removal, file deletion, personal cloud copy, and unallowed-domain browsing. Any unsupported indicator must still be selected in the Purview portal.

## Devon IRM Triggering

`Invoke-AgentRunbook.ps1` includes a Devon Reyes IRM sequence that can be forced with:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent devon.reyes -Services irm
```

The sequence randomly combines Microsoft 365 download, archive, obfuscation, label downgrade, external exfiltration, and delete operations.

## Manual Follow-Up

The script prints portal steps for IRM indicators, priority user group setup, and DSPM for AI enablement. Some IRM/DSPM settings require portal interaction even when policy creation is automated.
