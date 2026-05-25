# Get-RunbookStatus.ps1

## Purpose

Shows recent Azure Automation `Invoke-AgentRunbook` jobs, with optional stream/output details and schedule information.

## Execution

```powershell
.\tools\Get-RunbookStatus.ps1
.\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams
.\tools\Get-RunbookStatus.ps1 -Agent laura.gomez -IncludeOutput
.\tools\Get-RunbookStatus.ps1 -ShowSchedules
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `Last`: number of jobs to show.
- `SinceHours`: lookback window.
- `Agent`: filter by agent.
- `IncludeStreams`: include warning/error stream counts/snippets.
- `IncludeOutput`: include job output.
- `ShowSchedules`: show Automation schedules.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. Use it after Step `5` and for ongoing operations.

