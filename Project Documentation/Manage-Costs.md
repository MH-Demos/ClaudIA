# Manage-Costs.ps1

## Purpose

Cost utility for checking Azure spend, estimating monthly cost, pausing/resuming Fabric, reducing schedules, restoring schedules, and printing optimization recommendations.

## Execution

```powershell
.\Manage-Costs.ps1 -Action Status
.\Manage-Costs.ps1 -Action Estimate
.\Manage-Costs.ps1 -Action PauseFabric
.\Manage-Costs.ps1 -Action ReduceSchedule
.\Manage-Costs.ps1 -Action Recommendations
```

## Parameters

- `Action` mandatory. Valid values: `Status`, `Estimate`, `PauseFabric`, `ResumeFabric`, `ReduceSchedule`, `FullSchedule`, `Recommendations`.
- `ConfigPath`: path to `config/agents.json`.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. It is an operational script used after deployment.

## Alternatives

Use Azure Portal Cost Management for billing-level analysis. Use this script for lab-specific levers such as Automation schedules and Fabric capacity.

