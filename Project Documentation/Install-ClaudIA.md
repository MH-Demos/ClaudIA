# Install-ClaudIA.ps1

## Purpose

Main deployment wizard for the lab. It deploys or resumes the full ClaudIA environment: users, licenses, app registration, Azure infrastructure, collaboration spaces, sensitivity labels, runbook, DLP/IRM policies, workbook, Activity Story Map, and optional BrowserAgent cloud automation.

## Execution

```powershell
.\Install-ClaudIA.ps1
.\Install-ClaudIA.ps1 -UseExistingUsers -Auto
.\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites -UseInstallationDefinitions
.\Install-ClaudIA.ps1 -DryRun
```

## Parameters

- `ConfigPath`: path to `agents.json`. Default is `config/agents.json`.
- `SkipPrerequisites`: skips Step `0`.
- `Step`: runs a specific step. Step `4` includes `4a`, `4b`, `4c`; Step `6` includes `6a`, `6b`, `6c`.
- `DryRun`: shows intended changes where supported.
- `UseExistingUsers`: selects existing Entra ID users instead of creating users from config.
- `UseInstallationDefinitions`: merges values from `config/Installation_definitions.json` and avoids re-prompting for known installation values.
- `Auto`: uses default answers for many prompts.
- `AgentPassword`: shared lab password to use/reset/store for agents.

## Installer Steps

- `0`: prerequisites via `prerequisites/Test-Prerequisites.ps1`.
- `1`: create/select agents via local logic and `modules/Select-ExistingUsers.ps1`.
- `2`: license assignment and MFA exclusion group.
- `3`: app registration via `modules/Register-AgentApp.ps1`.
- `4`: Azure infrastructure via `modules/Deploy-AzureInfra.ps1`; then ADX via `tools/Deploy-AdxTelemetry.ps1`.
- `4a`: Microsoft 365 collaboration via `modules/Provision-M365Collaboration.ps1`.
- `4b`: sensitivity labels via `modules/Provision-SensitivityLabels.ps1`.
- `4c`: Fabric via `modules/Provision-Fabric.ps1`.
- `5`: Key Vault secrets, Automation variables, runbook, schedules via `modules/Deploy-Runbook.ps1`.
- `6a`: core DLP via `modules/Configure-CoreDLP.ps1`.
- `6b`: DSPM for AI DLP via `modules/Configure-DLP.ps1`.
- `6c`: IRM via `modules/Configure-IRM.ps1`.
- `7`: workbook via `modules/Deploy-Workbook.ps1`.
- `8`: Activity Story Map via `modules/Deploy-ActivityStoryMap.ps1`.
- `9`: BrowserAgent cloud automation via `tools/Deploy-BrowserAgentInfra.ps1` and `tools/Deploy-BrowserAgentScheduledJobs.ps1`.

## Notes

This is the only script intended as the normal entry point. Use tool scripts for maintenance after the first deployment.
