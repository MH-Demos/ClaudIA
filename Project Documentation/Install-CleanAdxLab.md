# Install-CleanAdxLab.ps1

## Purpose

End-to-end orchestrator for a clean ADX-backed lab installation. It updates config values, runs base installer steps, provisions ADX, publishes the runbook, optionally adds storyline agents, and can run a smoke test.

## Execution

```powershell
.\tools\Install-CleanAdxLab.ps1 -DryRun
.\tools\Install-CleanAdxLab.ps1 -SubscriptionId '<sub>' -ResourceGroup 'IA-NewDemo' -Location westus -Domain contoso.example -UseExistingUsers -Auto
```

## Parameters

- `ConfigPath`, `InstallationDefinitionsPath`
- `SubscriptionId`, `ResourceGroup`, `Location`, `Domain`
- `AutomationAccountName`, `OpenAiAccountName`, `KeyVaultName`
- `AdxTenantId`, `AdxClientId`, `AdxClientSecret`, `AdxClientSecretName`, `AdxM365Scope`
- `UseExistingUsers`, `Auto`
- `SkipBaseWizard`, `SkipAdxProvisioning`, `SkipRunbookDeploy`
- `AddStorylineAgents`, `ResetStorylinePasswords`
- `SkipSmokeTest`, `SmokeTestAgent`
- `KeepExistingAdxConfig`
- `DryRun`

## Installer Integration

Not called by `Install-ClaudIA.ps1`; this tool calls the installer and related tools as a higher-level orchestration path.

## Alternatives

Use the main installer directly for interactive deployments.

