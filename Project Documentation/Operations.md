# Operations

## After Deployment

Check the generated installation state:

```powershell
Get-Content .\config\Installation_definitions.json -Raw | ConvertFrom-Json
```

Validate configuration consistency:

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
```

Check recent jobs:

```powershell
.\tools\Get-RunbookStatus.ps1 -Last 20 -IncludeStreams
```

Run a single agent:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
```

Run all agents:

```powershell
.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

## Common Maintenance

Republish runbook code after changes:

```powershell
.\tools\Publish-RunbookOnly.ps1
```

Reset all agent passwords and synchronize Key Vault:

```powershell
.\tools\Reset-AgentPasswords.ps1 -All
```

Add storyline agents:

```powershell
.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles -StoreInKeyVault -UpdateAutomationVariables
```

Publish Story Map images:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

## Cost Controls

Show current status:

```powershell
.\Manage-Costs.ps1 -Action Status
```

Estimate cost:

```powershell
.\Manage-Costs.ps1 -Action Estimate
```

Reduce schedules:

```powershell
.\Manage-Costs.ps1 -Action ReduceSchedule
```

Restore full schedules:

```powershell
.\Manage-Costs.ps1 -Action FullSchedule
```

