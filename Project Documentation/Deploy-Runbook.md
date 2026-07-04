# Deploy-Runbook.ps1

## Purpose

Stores agent and app secrets in Key Vault, writes non-secret Automation variables,
uploads `modules/Invoke-AgentRunbook.ps1` to Azure Automation, publishes it, creates
schedules, and creates the Azure Monitor job-failure alert.

> `modules/Invoke-AgentRunbook.ps1` is a GENERATED artifact: edit the source parts under
> `modules/runbook/NN-*.ps1` and run `tools/Build-Runbook.ps1` before Step 5 ships it.

Step 5 FAILS FAST when `tenant.country` does not match a locale under `config/locales/`
(US, FR, UK, DE; GB accepted as UK alias) -- fix the config rather than expecting a
silent fallback.

## Execution

```powershell
.\modules\Deploy-Runbook.ps1 -Config $config -AgentPassword '<password>'
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 5 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `AgentPassword`: password to store for agent accounts when required.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `5`.

## Variables Created

Automation variables include `AgentTenantId`, `AgentAppId`, `AgentKeyVaultName`, `AgentClientSecretName`, `AgentConfig`, `AgentEmailThreads`, `AgentLocale` and `AgentSitReference` (encrypted, locale content pack), `AgentTeamsGroupId`/`AgentTeamsChannels`, Fabric identifiers when enabled, and `AgentPwdSecret-<sam>`.

Secrets are stored in Key Vault, including `agent-client-secret` and per-agent password secrets. The app client secret is rotated with `--append` and stale `agent-deploy` secrets are pruned at the end of the run (never touching secrets younger than 15 minutes), so scheduled runbooks keep working if Step 5 fails mid-run.

## Monitoring

Step 5 creates the metric alert `claudia-runbook-job-failures` (job Failed/Suspended/Stopped,
1-hour window). If `monitoring.alertEmail` is set in the config, an action group
`ag-claudia-alerts` delivers email; otherwise the alert is visible in Azure Monitor > Alerts.

## Alternatives

Use `tools\Publish-RunbookOnly.ps1` for code-only runbook updates after Step `5` has completed.

