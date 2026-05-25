# BrowserAgents

BrowserAgents use Playwright to drive Microsoft 365 web experiences such as
Office Web, Outlook Web, SharePoint Web, and approved SaaS upload targets.

The goal is to generate user-attributed Microsoft 365 activity from browser UI
paths, while keeping Endpoint DLP device scenarios limited to the Windows 365
Cloud PC pilot.

## Banking Wave 1

The scheduled BrowserAgent service set now includes `banking` by default. This
loads `scenarios/banking-finance-wave1.json`, validates the first eight
web-feasible banking scenarios, and emits per-persona scenario telemetry with
`ScenarioId`, `CorrelationId`, `ImplementationMode`, sensitivity label, workload,
operation, risk score, and business context.

Run only the banking wave locally from the `ClaudIA` repo root:

```powershell
$env:BROWSER_AGENT_ADX_DISABLED='true'
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent devon.reyes -Services banking
```

Run the scheduler path for all agents:

```powershell
cd BrowserAgents
$env:BROWSER_AGENT_SERVICES='banking'
node scripts/run-scheduled.js
```

## Azure Workspace

Current workspace:

- Resource group: `rg-claudia-lab`
- Workspace: `pw-aa-claudia-lab`
- Location: `eastus`
- Workspace id: `44444444-4444-4444-4444-444444444444`
- Service URL:

```text
wss://eastus.api.playwright.microsoft.com/playwrightworkspaces/44444444-4444-4444-4444-444444444444/browsers
```

Validate the Azure resource:

```powershell
..\tools\Test-BrowserAgentWorkspace.ps1
```

## Setup

Install Node.js with npm on the runner machine, then:

```powershell
cd BrowserAgents
Copy-Item .env.sample .env
npm install
npx playwright install chromium
```

If PowerShell cannot find `npm` or `npx` after Node.js installation, add Node.js
to the current session path:

```powershell
$env:PATH = "C:\Program Files\nodejs;$env:PATH"
```

Authenticate Azure CLI in the tenant that owns the workspace:

```powershell
az login --tenant 00000000-0000-0000-0000-000000000000
az account set --subscription 11111111-1111-1111-1111-111111111111
```

The signed-in Azure user or service principal needs `Playwright Workspace Contributor`
or `Playwright Workspace Owner` on the workspace to run tests.

## First Priya Test

Capture Priya's Microsoft 365 browser session:

```powershell
npm run auth:priya
```

This is intentionally interactive for the first run. It creates:

```text
.auth/priya.sharma.json
```

Alternatively, from the repo root, use the Key Vault-backed wrapper:

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma
```

Run local browser smoke tests:

```powershell
npm run office:priya
```

Or from the repo root:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1
```

Run against Azure-hosted browsers:

```powershell
npm run office:priya:azure
```

Or from the repo root:

```powershell
.\tools\Invoke-BrowserAgentSmoke.ps1 -Azure
```

The Azure run uses `@azure/playwright` with Microsoft Entra authentication through
`DefaultAzureCredential`. The runner identity must have `Playwright Workspace
Contributor` or `Playwright Workspace Owner` on the workspace.

## Next Automation Targets

After the smoke test is reliable, add UI flows in this order:

1. Banking Wave 1 scenario telemetry and schedule validation.
2. OWA compose/send with sensitivity label.
3. Word Web open existing DOCX and apply/change sensitivity label from the UI.
4. SharePoint Web upload to the department library.
5. Browser upload to a sensitive service domain configured in Purview.
6. Browser paste to a monitored SaaS site.

## Important Limits

- Playwright Workspaces provide cloud-hosted browsers, not a full managed Windows
  endpoint. These flows can produce Microsoft 365 web app user activity, but they
  do not replace Endpoint DLP device signals.
- Use Windows 365 / Endpoint DLP for print, removable media, local clipboard,
  network share, unallowed app, and screen capture scenarios.
- Graph `assignSensitivityLabel` remains useful for seeding files, but it can show
  `SHAREPOINT\system` in Activity Explorer. BrowserAgents are intended for the
  user-attributed UI path.
