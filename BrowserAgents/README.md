# BrowserAgents

BrowserAgents use Playwright to drive Microsoft 365 web experiences such as Office Web, Outlook Web, SharePoint Web, Teams web scenarios, and approved SaaS upload targets.

The goal is to generate user-attributed activity through browser UI paths, not only through Graph or backend automation. This helps ClaudIA produce more realistic activity for Microsoft 365, Purview, Defender, ADX, MDCA, and Activity Story Map demos.

## What BrowserAgents Do

BrowserAgents can help simulate:

- Opening Microsoft 365 web apps.
- Uploading or editing files through browser workflows.
- Sending or composing web-based email scenarios.
- Triggering user-attributed activity where UI interaction is important.
- Running selected scenario packs such as banking or finance activity waves.
- Sending normalized telemetry back to ClaudIA's activity pipeline.

BrowserAgents complement the main ClaudIA automation runbooks. They do not replace Endpoint DLP, Windows device signals, or full managed endpoint testing.

## Important Limits

- Playwright Workspaces provide cloud-hosted browsers, not a full managed Windows endpoint.
- BrowserAgents can produce Microsoft 365 web-app activity, but they do not replace Endpoint DLP device signals.
- Use Windows 365 / Endpoint DLP for print, removable media, local clipboard, network share, unallowed app, and screen capture scenarios.
- Browser sessions are sensitive local artifacts and must never be committed.
- Graph `assignSensitivityLabel` remains useful for seeding files, but it can show system-attributed activity. BrowserAgents are intended for user-attributed UI paths.

## Setup

Install Node.js with npm on the runner machine, then from the repository root:

```powershell
cd BrowserAgents
Copy-Item .env.sample .env
npm install
npx playwright install chromium
cd ..
```

If PowerShell cannot find `npm` or `npx` after Node.js installation, add Node.js to the current session path:

```powershell
$env:PATH = "C:\Program Files\nodejs;$env:PATH"
```

Authenticate Azure CLI in the tenant that owns the Playwright workspace:

```powershell
az login --tenant 00000000-0000-0000-0000-000000000000
az account set --subscription 11111111-1111-1111-1111-111111111111
```

The signed-in Azure user, service principal, or managed identity needs the required Playwright Workspace permissions on the workspace.

## Local Authentication State

Some browser scenarios require an interactive first login to create a local browser session state.

Example using the Key Vault-backed wrapper from the repository root:

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma
```

This creates local session state under `BrowserAgents/.auth`.

Do not commit this folder.

## Run A Smoke Test

From the repository root:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1
```

Run against Azure-hosted browsers:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1 -Azure
```

## Run A Daily Browser Agent

Example for one persona and one service set:

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa
```

Example for a controlled risky persona scenario:

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent devon.reyes -Services banking
```

## Banking Wave 1

The scheduled BrowserAgent service set can include `banking` scenarios. This loads `scenarios/banking-finance-wave1.json`, validates web-feasible banking scenarios, and emits per-persona scenario telemetry such as:

- `ScenarioId`
- `CorrelationId`
- `ImplementationMode`
- Sensitivity label
- Workload
- Operation
- Risk score
- Business context

Run only the banking wave locally from the ClaudIA repo root:

```powershell
$env:BROWSER_AGENT_ADX_DISABLED='true'
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent devon.reyes -Services banking
```

Run the scheduler path for selected services:

```powershell
cd BrowserAgents
$env:BROWSER_AGENT_SERVICES='banking'
node scripts/run-scheduled.js
cd ..
```

## Azure Playwright Workspace

Validate the Azure resource:

```powershell
.\tools\Test-BrowserAgentWorkspace.ps1
```

Configuration values are read from `config/agents.json`. Avoid hardcoding workspace IDs, tenant IDs, or subscription IDs in public documentation.

## Safety Rules

Do not commit:

- `.auth` session files.
- `.env` files.
- Playwright reports.
- Test results.
- Screenshots containing tenant identifiers, user identifiers, or sensitive data.
- Downloaded files from a real tenant.

Use only lab tenants, synthetic users, fictional data, and approved external recipients.

## Next Automation Targets

Typical expansion order:

1. Banking and finance scenario telemetry.
2. OWA compose/send with sensitivity label behavior.
3. Word Web open/edit/label flows.
4. SharePoint Web upload to department libraries.
5. Browser upload to monitored SaaS domains.
6. Browser paste to monitored SaaS sites.
7. Additional Activity Story Map correlation events.
