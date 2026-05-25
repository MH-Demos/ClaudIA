# Deploy-Runbook.ps1

## Purpose

Stores agent and app secrets in Key Vault, writes non-secret Automation variables, uploads `modules/Invoke-AgentRunbook.ps1` to Azure Automation, publishes it, and creates schedules.

## Execution

```powershell
.\modules\Deploy-Runbook.ps1 -Config $config -AgentPassword '<password>'
```

Normally run by:

```powershell
.\Install-AutonomousAgents.ps1 -Step 5 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `AgentPassword`: password to store for agent accounts when required.

## Installer Integration

Called by `Install-AutonomousAgents.ps1` in Step `5`.

## Variables Created

Automation variables include `AgentTenantId`, `AgentAppId`, `AgentKeyVaultName`, `AgentClientSecretName`, `AgentConfig`, `AgentEmailThreads`, and `AgentPwdSecret-<sam>`.

Secrets are stored in Key Vault, including `agent-client-secret` and per-agent password secrets.

## Alternatives

Use `tools\Publish-RunbookOnly.ps1` for code-only runbook updates after Step `5` has completed.

