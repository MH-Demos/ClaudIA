# Test-Prerequisites.ps1

## Purpose

Validates local and cloud prerequisites before deployment.

## Execution

```powershell
.\prerequisites\Test-Prerequisites.ps1
.\prerequisites\Test-Prerequisites.ps1 -ConfigPath .\config\agents.json
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `0`.

## Alternatives

Use `-SkipPrerequisites` on the installer only when prerequisite validation was already performed.

