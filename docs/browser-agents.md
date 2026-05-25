# BrowserAgents

BrowserAgents are the browser-based execution layer for the lab. They use Azure
App Testing Playwright Workspaces to run cloud-hosted browsers against Microsoft
365 web experiences such as Office Web, Outlook Web, SharePoint Web, and SaaS
upload/paste targets.

This layer is intended to reduce dependency on Windows 365 / endpoint VMs for
activities that can be produced through web apps.

## Current Azure Resources

| Setting | Value |
| --- | --- |
| Subscription | `11111111-1111-1111-1111-111111111111` |
| Resource group | `rg-claudia-lab` |
| Provider | `Microsoft.LoadTestService` |
| Local auth | `Disabled` |
| Reporting | `Disabled` |

| Browser region key | Workspace | Azure region | Workspace ID | Personas |
| --- | --- | --- | --- | --- |
| `americas` | `pw-aa-claudia-lab` | `eastus` | `44444444-4444-4444-4444-444444444444` | Carlos, David, Diego, Emily, James, Laura, Miguel, Sofia |
| `europe` | `pw-aa-claudia-lab-eu` | `westeurope` | `912454ad-12ba-4bd3-809a-dac74dbf1c0f` | Alexander, Ana, Marcus, Devon |
| `asia` | `pw-aa-claudia-lab-asia` | `eastasia` | `e051aa82-548a-4b13-bdf2-397b5389b802` | Priya |

Azure currently reports Playwright Workspaces in `East US`, `West US 3`,
`West Europe`, and `East Asia` for this subscription. Brazil and UK are not
available for this provider at the time of deployment, so South America is
mapped to `eastus` and Europe is mapped to `westeurope`.

Validate it with:

```powershell
.\tools\Test-BrowserAgentWorkspace.ps1
```

Recreate or update it with:

```powershell
.\tools\Deploy-BrowserAgentInfra.ps1 -AssignCurrentUserRole
```

## Why BrowserAgents

Graph `assignSensitivityLabel` is service-attributed and can show
`SHAREPOINT\system` in Activity Explorer. BrowserAgents are meant to use the same
web UI surfaces that a person uses, so Microsoft 365 and Purview have a better
chance of recording user-attributed events.

Good browser-agent candidates:

- OWA compose/send with a sensitivity label.
- Word Web / Excel Web / PowerPoint Web label apply or label change.
- SharePoint Web upload/download/open actions.
- Browser upload to SaaS sites included in Purview sensitive service domain groups.
- Browser paste into monitored web apps.
- Copilot web interactions where browser interaction is required.

Keep Windows 365 / Endpoint DLP for:

- File copied to clipboard from local apps.
- File copied to network share.
- File printed from local apps.
- Removable media.
- Unallowed local apps.
- Screen capture.

## Runner Model

Playwright Workspaces provide cloud-hosted browsers. They do not replace a runner.
The Playwright tests still need to run from one of these places:

| Runner | VM needed | Notes |
| --- | --- | --- |
| Local admin workstation | No Azure VM | Good for first interactive auth capture and debugging. |
| Azure DevOps / GitHub Actions | No Azure VM | Good for scheduled repeatable browser flows. |
| Azure Container Apps Job | No full VM | Good long-term target for autonomous execution from Azure. Needs container packaging and secure auth/session storage. |
| Windows 365 Cloud PC | Yes | Use only for endpoint-specific scenarios or visual troubleshooting. |

## Authentication Model

Start with interactive session capture for Priya:

```powershell
cd .\BrowserAgents
Copy-Item .env.sample .env
npm install
npm run auth:priya
```

This creates a Playwright storage state file:

```text
BrowserAgents\.auth\priya.sharma.json
```

That file is sensitive because it contains browser session state. Treat it like a
secret. For Azure runners, store it in Key Vault or a protected storage container
and inject it at runtime.

## First Validation Plan

1. Validate workspace resource:

   ```powershell
   .\tools\Test-BrowserAgentWorkspace.ps1
   ```

2. On a machine with `npm`, install BrowserAgents dependencies:

   ```powershell
   cd .\BrowserAgents
   Copy-Item .env.sample .env
   npm install
   ```

3. Capture Priya browser session:

   ```powershell
   npm run auth:priya
   ```

4. Run local Office/OWA smoke:

   ```powershell
   npm run office:priya
   ```

5. Run with cloud-hosted browsers:

   ```powershell
   npm run office:priya:azure
   ```

6. If Activity Explorer shows the expected user for Office Web / OWA events,
   add the first real scenario: OWA compose with sensitivity label.

## Agent Initialization Preflight

Before running daily browser activity across many users, initialize and validate
each BrowserAgent. This avoids scaling stale sessions, missing passwords, or web
service prompts across the whole lab.

Validate one user with an existing captured session:

```powershell
.\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma -Services office,owa,copilot,teams -SkipAuth
```

Capture or refresh the browser session first:

```powershell
.\tools\Initialize-BrowserAgents.ps1 -Agents priya.sharma -RefreshAuth -Services office,owa,copilot
```

Initialize every configured agent:

```powershell
.\tools\Initialize-BrowserAgents.ps1 -All -Services office,owa,copilot -ContinueOnFailure
```

The initializer writes one JSON result per user under:

```text
BrowserAgents\test-results\preflight
```

It also writes `browser_preflight` events to ADX so readiness can be included in
the Activity Story Map or operational dashboards.

## Daily Browser Activity

The first daily browser scenarios are:

| Scenario | Test | Default behavior |
| --- | --- | --- |
| M365 Copilot web prompt | `tests/m365-copilot-daily-activity.spec.js` | Sends a synthetic sensitive prompt to M365 Copilot web. |
| OWA daily mail draft | `tests/owa-daily-activity.spec.js` | Creates a sensitive draft. It does not send unless `BROWSER_AGENT_SEND_EMAIL=true`. |

Run locally:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1 -Daily
```

Run on Azure Playwright Workspaces:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1 -Daily -Azure
```

To send the OWA message during scheduled runs:

```powershell
$env:BROWSER_AGENT_SEND_EMAIL = "true"
$env:BROWSER_AGENT_EMAIL_RECIPIENT = "demo.recipient@example.com"
.\tools\Invoke-BrowserAgentSmoke.ps1 -Daily -Azure
```

For early validation, keep `BROWSER_AGENT_SEND_EMAIL` unset so the test creates a
draft without sending mail.

The OWA test now verifies successful send by opening `Sent Items`. A test should
not be considered successful just because the `Send` button was clicked; OWA can
leave messages in Drafts or Outbox when a privacy prompt, policy tip, or schedule
send prompt interrupts the flow.

## ADX Telemetry

BrowserAgents write first-party telemetry to the same ADX table used by the
Activity Story Map. The source field is `BrowserAgent`.

The browser telemetry layer records:

- `browser_session` events such as `OWAOpen`.
- `email` events such as `EmailComposed`, `EmailDrafted`, and `EmailSent`.
- `copilot` events such as `CopilotInteraction` or `AIAppInteraction`.

Query recent BrowserAgent events with:

```powershell
.\tools\Get-BrowserAgentTelemetry.ps1 -Agent priya.sharma -SinceMinutes 60
```

BrowserAgent ADX ingestion reads the app-dataagent client secret from Key Vault
and uses the ADX configuration in `config\agents.json`. For hosted runners that
do not have Azure CLI available, inject the secret as:

```powershell
$env:BROWSER_AGENT_ADX_CLIENT_SECRET = "<client-secret-value>"
```

Set `BROWSER_AGENT_ADX_DISABLED=true` to run browser tests without telemetry.

Run a single BrowserAgent through the main test entry point:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent priya.sharma -BrowserAgent -BrowserServices owa,copilot
```

Run a BrowserAgent full test for selected users:

```powershell
.\tests\Test-FullRun.ps1 -BrowserAgent -Agents priya.sharma,ana.rodriguez -BrowserServices owa,copilot -ContinueOnFailure
```

Send external OWA mail from the BrowserAgent path:

```powershell
.\tests\Test-SingleAgent.ps1 `
  -Agent priya.sharma `
  -BrowserAgent `
  -BrowserServices owa `
  -ExternalRecipient 'demo.recipient@example.com' `
  -SendEmail `
  -Sensitive `
  -Label General
```

## Multi-Region Model

Playwright Workspaces are regional. The current workspace runs in `eastus`.
Additional regions can be added later to generate geographically distributed
browser activity.

Recommended regional expansion:

| Region intent | Azure region | Notes |
| --- | --- | --- |
| Americas | `eastus` | Current pilot workspace. |
| US West | `westus3` | Useful when west-coast activity matters. |
| Europe | `westeurope` | Useful for EU working hours and regional demo movement. |
| Asia | `eastasia` | Useful for APAC working hours. |

For each region:

1. Create a Playwright Workspace in the target region.
2. Add a matching `.env` or scheduled job config with that region's
   `PLAYWRIGHT_SERVICE_URL`.
3. Set `BROWSER_AGENT_REGION`, for example `US-East`, `EU-West`, or `APAC-East`.
4. Run the same BrowserAgent tests with the region-specific environment.

The BrowserAgent scenario content includes the `BROWSER_AGENT_REGION` value, so
ADX/Purview evidence can be correlated with the intended geography.

Longer term, run these tests from an Azure Container Apps Job or CI pipeline and
store `.auth/*.json` session state in Key Vault or protected Storage. Playwright
Workspaces provide cloud browsers; the runner still needs to execute the tests.

## Resource References

- Playwright Workspaces overview: https://learn.microsoft.com/en-us/azure/app-testing/playwright-workspaces/overview-what-is-microsoft-playwright-workspaces
- Playwright Workspaces reporting quickstart: https://learn.microsoft.com/en-us/azure/app-testing/playwright-workspaces/quickstart-advanced-diagnostic-with-playwright-workspaces-reporting
- Playwright Workspaces access: https://learn.microsoft.com/en-us/azure/app-testing/playwright-workspaces/how-to-manage-workspace-access
- Playwright Workspaces ARM reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.loadtestservice/playwrightworkspaces


