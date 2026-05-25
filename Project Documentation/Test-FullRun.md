# Test-FullRun.ps1

## Purpose

Starts Azure Automation jobs for multiple configured agents, optionally in parallel, and can wait for ADX ingestion.

## Execution

```powershell
.\tests\Test-FullRun.ps1
.\tests\Test-FullRun.ps1 -Agents ana.rodriguez,carlos.delgado -ADXWaitMinutes 2
.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5 -NoADXWait
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `Agents`: subset of agents to run.
- `PollSeconds`: polling interval for job completion.
- `ADXWaitMinutes`: wait time after jobs for ADX ingestion.
- `Parallel`: starts jobs in parallel.
- `ThrottleLimit`: maximum concurrent agent starts.
- `NoADXWait`: skips ADX wait.

## Installer Integration

Not called by `Install-ClaudIA.ps1`, but suggested at the end of install.

## Alternatives

Use `tests\Test-SingleAgent.ps1` for one agent or `tools\Invoke-ActivityStoryMapRefresh.ps1` when the goal is to refresh Story Map data.

