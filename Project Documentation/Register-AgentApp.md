# Register-AgentApp.ps1

## Purpose

Creates or updates the Entra ID app registration `app-claudia-dataagent`, which is used by the runbook for Graph and telemetry authentication flows.

## Execution

```powershell
.\modules\Register-AgentApp.ps1 -Domain contoso.example
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 3 -SkipPrerequisites
```

## Parameters

- `Domain`: tenant domain.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `3`.

## Notes

Consent is validated by shared helpers in `Common.ps1`. The current app ID in installation state is `22222222-2222-2222-2222-222222222222`.

