# BrowserAgent Azure Automation

BrowserAgents can run automatically in Azure using Azure Container Apps Jobs plus Azure Playwright Workspaces.

## Runtime Model

- Azure Container Apps Job runs the Node.js BrowserAgent scheduler.
- Azure Playwright Workspaces provides the cloud browser.
- ADX remains the telemetry sink for the Activity Story Map.
- A private ACR stores the BrowserAgent image.

The first automation path packages `BrowserAgents/.auth/*.json` inside the private container image. This is acceptable for the lab, but treat that image as sensitive because browser session state is equivalent to an authenticated session. Refresh sessions with `Initialize-BrowserAgents.ps1` and redeploy the image when sessions expire.

## Deploy

Preview the plan:

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1
```

Deploy/update Azure resources and scheduled jobs:

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1 `
  -Deploy `
  -Services owa,copilot,internalai `
  -ExternalRecipient 'demo.recipient@example.com' `
  -SendEmail `
  -Sensitive
```

The script creates one scheduled Container Apps Job per schedule in `config\agents.json`. The schedule is converted to UTC cron at deployment time.

By default, weekend executions are throttled to 25% of selected agents through `BROWSER_AGENT_WEEKEND_ACTIVITY_PERCENT`. Override it during deployment with `-WeekendActivityPercent`.

## Regional Browser Execution

The lab uses one Container Apps environment and multiple Azure Playwright
Workspaces to create browser activity from different Azure regions.

| Browser region key | Workspace | Azure region | Job prefix | Agents |
| --- | --- | --- | --- | --- |
| `americas` | `pw-claudia-lab` | `eastus` | `browseragents` | `carlos.delgado,david.chen,diego.martinez,emily.johnson,james.wilson,laura.gomez,miguel.santos,sofia.lopez` |
| `europe` | `pw-claudia-lab-eu` | `westeurope` | `browseragents-eu` | `alexander.meyer,ana.rodriguez,marcus.olsson,devon.reyes` |
| `asia` | `pw-claudia-lab-asia` | `eastasia` | `browseragents-asia` | `priya.sharma` |

Brazil and UK are not currently listed for `Microsoft.LoadTestService/playwrightWorkspaces`
in this subscription. The closest supported split is Americas in East US,
Europe in West Europe, and Asia in East Asia.

Update one regional job set with:

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1 `
  -Deploy `
  -EnvironmentName cae-browseragents-adx-347fa5e9 `
  -JobNamePrefix browseragents-eu `
  -BrowserRegionKey europe `
  -Agents alexander.meyer,ana.rodriguez,marcus.olsson,devon.reyes `
  -Services owa,copilot,internalai `
  -ExternalRecipient 'demo.recipient@example.com' `
  -SendEmail `
  -Sensitive `
  -WeekendActivityPercent 25
```

## Validate

List job executions:

```powershell
az containerapp job execution list `
  --name browseragents-daily-morning `
  --resource-group rg-claudia-lab `
  -o table
```

Query BrowserAgent telemetry:

```powershell
.\tools\Get-BrowserAgentTelemetry.ps1 -SinceMinutes 180
```

## Known Operational Notes

- `sofia.lopez` must have a valid `BrowserAgents/.auth/sofia.lopez.json` before deploying all agents.
- If OWA redirects to another Microsoft 365 experience, re-run `Initialize-BrowserAgents.ps1` for that user and validate `owa` preflight before deployment.
- Container Apps cron schedules are UTC; daylight saving changes may require redeployment or a future schedule reconciler.


