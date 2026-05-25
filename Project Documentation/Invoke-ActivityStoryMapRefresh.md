# Invoke-ActivityStoryMapRefresh.ps1

## Purpose

Runs agent activity jobs so the Activity Story Map has fresh data in ADX. The map reads ADX live; this script refreshes data by generating new activity.

## Execution

```powershell
.\tools\Invoke-ActivityStoryMapRefresh.ps1
.\tools\Invoke-ActivityStoryMapRefresh.ps1 -Agents ana.rodriguez,sofia.lopez
.\tools\Invoke-ActivityStoryMapRefresh.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

## Parameters

- `Agents`: subset of agents.
- `Parallel`: run jobs in parallel.
- `ThrottleLimit`: max concurrency.
- `ADXWaitMinutes`: wait time for ADX ingestion.
- `NoADXWait`: skip ingestion wait.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. It wraps `tests\Test-FullRun.ps1`.

