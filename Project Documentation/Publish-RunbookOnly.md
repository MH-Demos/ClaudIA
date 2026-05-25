# Publish-RunbookOnly.ps1

## Purpose

Publishes the local `modules/Invoke-AgentRunbook.ps1` to Azure Automation without rotating credentials. It also refreshes non-secret effective config in Automation variables.

## Execution

```powershell
.\tools\Publish-RunbookOnly.ps1
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. Use after Step `5` when only runbook code or non-secret config changed.

## Alternatives

Run installer Step `5` when secrets, schedules, or runbook deployment need a full refresh.

