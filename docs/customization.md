# Customization Guide

## Changing the Number of Agents

Edit `config/agents.json` and remove or add entries in the `agents` array.

**Minimum**: 1 agent (for testing)
**Recommended**: 5-10 agents (realistic cross-department activity)
**Maximum**: Limited by E5 licenses available in your tenant

### Adding a new agent

Add an entry to the `agents` array:

```json
{
  "sam": "pdupont",
  "displayName": "Pierre Dupont",
  "department": "Marketing",
  "jobTitle": "Marketing Manager",
  "wave": 1,
  "workload": "SPO",
  "copilotLicense": false,
  "workingHours": { "start": 9, "end": 18 },
  "filesPerDay": [4, 7],
  "emailsPerDay": [2, 3],
  "style": "creative, visual, brand-focused",
  "topics": ["campaigns", "brand guidelines", "market research", "competitor analysis"]
}
```

### Removing an agent

Delete the entry from the `agents` array. The wizard will skip non-existent agents.

## Changing Departments

The solution supports any department name. Update the `department` field in agents.json. The runbook will automatically:
- Create SharePoint folders with the department name
- Route emails between agents in different departments
- Apply SIT detection based on department context

## Changing Workloads

Each agent has a `workload` field that determines their activity type:

| Workload | What it does | Graph API used |
| --- | --- | --- |
| `SPO` | Upload files to SharePoint department folder | PUT /sites/{id}/drive |
| `Teams` | Post in Teams department channel | POST channels/{id}/messages |
| `Chat` | Send 1:1 Teams chat messages | POST /chats + /chats/{id}/messages |
| `Lists` | Upload structured CSV data to SharePoint | PUT /sites/{id}/drive |
| `Fabric` | Upload multi-format files to Engineering/ subfolders | PUT /sites/{id}/drive |
| `Meetings` | Upload meeting notes + post summary in Teams | PUT + POST |

## Changing File Types

File type templates are embedded in the runbook (`modules/Invoke-AgentRunbook.ps1`). To add a new file type for a department:

1. Find the `$fileTypes` hashtable in the runbook
2. Add a new entry under the department:

```powershell
@{ Type='New_Report'; Ext='.csv'; Prompt='Generate a CSV with columns: ...' }
```

## Changing SIT Patterns

Edit `config/sit-reference.txt` to add or modify the SIT patterns injected into AI prompts. This file is appended to every agent's system prompt.

For example, to add a Belgian national number:

```
BELGIAN NATIONAL NUMBER (Numero national):
- Format: YY.MM.DD-XXX.XX
- MUST include keyword "numero national" within 300 chars
- Examples: 85.07.15-123.45
```

## Changing Email Thread Scenarios

Edit `config/email-threads.json` to add new multi-turn conversation scenarios. Each thread has:
- `threadName`: Display name for logging
- `messages`: Array of messages with `from`, `to`, and `instruction` for the AI

## Changing Schedules

Edit the `schedules` array in `config/agents.json`:

```json
"schedules": [
  { "name": "once-daily", "hour": 10, "minute": 0, "timezone": "Romance Standard Time" }
]
```

Supported timezones: any Windows timezone name (e.g., "Romance Standard Time" for CET, "UTC", "Pacific Standard Time").

## Enabling the Fabric/Data Engineering Workload

Emma Leroy (eleroy) generates 30 data engineering file types across 8 formats: CSV datasets, JSON schemas/configs, Markdown reports (DPIA, incidents, runbooks), HTML dashboards, SVG diagrams, XML integrations (DSN, SEPA), and TXT logs. Files contain realistic PII matching 7 Microsoft SITs: NIR, IBAN, Tax ID, SIRET, carte bancaire, email, telephone.

**Dual-write architecture** (v1.5): files are uploaded to both:
- **OneLake Lakehouse** (Fabric) -- for Purview Data Map scanning, DSPM for AI, Power BI
- **SharePoint** -- for DLP policies, auto-labeling, IRM, Activity Explorer audit logs

### Steps to enable (SharePoint only, no F2 cost)

1. Set `fabricEnabled: true` in `config/agents.json` (under `infrastructure`)
2. Ensure Emma Leroy (eleroy) has a license with SharePoint access (E3/E5/E7)
3. Re-run Step 5 to update the runbook config:
   ```powershell
   .\Install-AutonomousAgents.ps1 -Step 5 -SkipPrerequisites
   ```
4. On the next scheduled run, Emma will generate 7-13 files/day across 30 templates (8 formats)

### Steps to enable OneLake dual-write (requires F2 capacity)

The wizard now automates this via **Step 4c** (Fabric Provisioning):

```powershell
# The wizard handles everything:
.\Install-AutonomousAgents.ps1 -Step 4
# At Step 4c, choose [C]reate or [E]xisting
```

**Manual alternative** (if not using the wizard):

1. Deploy an F2 capacity in Azure Portal (~$262/month) or resume an existing one
2. Create a Fabric workspace + lakehouse (or use existing)
3. Add `storage.azure.com/user_impersonation` scope to the Entra app + admin consent
4. Store workspace/lakehouse IDs as Automation variables:
   ```powershell
   az automation variable create --automation-account-name aa-agents --resource-group <RG> \
       --name AgentFabricWorkspaceId --value '"<workspace-id>"'
   az automation variable create --automation-account-name aa-agents --resource-group <RG> \
       --name AgentFabricLakehouseId --value '"<lakehouse-id>"'
   ```
5. Re-deploy the runbook (Step 5) -- it will auto-detect OneLake variables and dual-write
6. Pause F2 capacity when not demoing to save costs

## Enabling Copilot Queries

1. Ensure Copilot M365 licenses are available
2. Set `copilotLicense: true` on the agents you want to use Copilot
3. The wizard assigns licenses automatically
4. Each licensed agent will run 3 AI-generated search queries per run

## Sentinel Workspace Modes

The wizard supports two Sentinel deployment modes for the security analytics rules (agent monitoring + privilege escalation detection):

### Mode 1: Integrated (default)

Sentinel is enabled on the **same Log Analytics workspace** used for the agent telemetry workbook. This is the simplest setup.

```json
"sentinelEnabled": true,
"sentinelWorkspace": "",
"sentinelResourceGroup": ""
```

**Behavior**: The wizard enables Sentinel on `la-agents`, creates 4 analytics rules (AI monitoring + privilege escalation), and deploys the `Remediate-AgentPrivilegeEscalation` runbook.

**Limitation**: Some Managed Environment (ME/MCAP) tenants block Sentinel onboarding. In that case, the wizard shows `[WARN]` and falls back to deploying only the remediation runbook (scan mode, no Sentinel alerts).

### Mode 2: External Sentinel workspace

Use an **existing Sentinel-enabled workspace** (e.g., your SOC workspace) for the security rules, while keeping the agent workbook on the dedicated `la-agents` workspace.

```json
"sentinelEnabled": true,
"sentinelWorkspace": "la-soc-prod",
"sentinelResourceGroup": "rg-soc"
```

**Behavior**: The wizard creates the analytics rules on the external Sentinel workspace. The agent workbook stays on `la-agents`. The `AuditLogs` table must be ingested in the external workspace (via Entra diagnostic settings or Sentinel Azure AD connector).

**Setup during wizard**:
```
Sentinel workspace (Enter=use agent LA, or existing LA name): la-soc-prod
Sentinel workspace RG: rg-soc
```

### What gets deployed

| Component | Integrated | External |
| --- | --- | --- |
| Sentinel onboarding | On `la-agents` | Skipped (already enabled) |
| 3 AI monitoring rules | On `la-agents` | On external workspace |
| Privilege escalation rule | On `la-agents` | On external workspace |
| Remediation runbook | In Automation Account | In Automation Account |
| MI permissions (Graph) | `Group.ReadWrite.All` + `User.Read.All` + `RoleManagement.Read.Directory` | Same |

## Azure OpenAI Model and Scaling

The wizard prompts for AI model settings during first-time setup. You can also edit `config/agents.json` directly:

```json
"infrastructure": {
    "openAiModel": "gpt-4o",          // Chat model for content generation
    "openAiTpm": 30,                   // Tokens-per-minute capacity (10-120)
    "openAiImageModel": "",            // Set to "dall-e-3" for image generation
}
```

### Choosing a model

| Goal | Recommended model | `openAiTpm` | Monthly cost (3x/day) |
| --- | --- | --- | --- |
| Cost-efficient lab | `gpt-4o-mini` | 10 | ~$0.30 |
| Realistic cross-dept content | `gpt-4o` (default) | 30 | ~$4.80 |
| Long-form documents | `gpt-4.1-mini` | 30 | ~$0.53 |
| Maximum content quality | `gpt-4.1` | 60 | ~$2.64 |

See [costs.md](costs.md) for detailed tokenization breakdown.

### Adding image generation

Set `openAiImageModel` to `"dall-e-3"` to deploy DALL-E alongside the chat model. The runbook does not yet consume images — this is provisioned for future workloads (badge scans, org charts, document images).

## Multi-Country Locale Support

The solution supports 4 countries out of the box. Each locale provides country-specific PII patterns, personas, document templates, and scan image formats.

### Available Locales

| Country | Code | SIT Types | Personas | Documents |
| --- | --- | --- | --- | --- |
| **France** (default) | `FR` | NIR, IBAN FR76, Numero fiscal, EU Debit Card | Alice Moreau, Marc Lefebvre... | Bulletin de paie, DPAE, DSN |
| **United States** | `US` | SSN, Bank Routing+Account, EIN, ITIN, Passport | John Smith, Sarah Johnson... | W-2, I-9, Pay Stub, 1099 |
| **United Kingdom** | `UK` | NINO, Sort Code+Account, UTR, NHS Number | James Thompson, Emma Watson... | P60, HMRC Starter, Payslip |
| **Germany** | `DE` | Steuer-ID, IBAN DE, Personalausweis, SV-Nummer | Max Mueller, Anna Schmidt... | Lohnabrechnung, Arbeitsvertrag |

### Selecting a Country

During first-time setup, the wizard prompts for country:
```
  --- Geographic Content (PII patterns + personas) ---
    Available locales:
      [FR] fr - CorpLab SAS
      [US] en - CorpLab Inc.
      [UK] en - CorpLab Ltd
      [DE] de - CorpLab GmbH
    Country [FR]: US
    Loaded 10 personas from US locale
```

Or set directly in `agents.json`:
```json
"tenant": {
    "domain": "contoso.onmicrosoft.com",
    "country": "US"
}
```

### Creating a Custom Locale

Copy an existing locale file and modify:
```powershell
Copy-Item config/locales/FR.json config/locales/JP.json
# Edit JP.json: change country, language, personas, sitReference, fileTypes, scanTemplates
```

Required fields: `country`, `language`, `currency`, `companyName`, `companyDescription`, `personas[]`, `sitReference`, `fileTypes{}`, `scanTemplates{}`, `piiGenerators{}`.

### What Changes Per Locale

| Component | Locale-driven | Universal |
| --- | --- | --- |
| Agent personas (names, titles) | Yes | |
| SIT patterns (AI prompts) | Yes | |
| File types (HR/Finance/Legal/Sales) | Yes | |
| Scan image labels + PII formats | Yes | |
| Engineering file types (30 templates) | | Yes (data eng is universal) |
| Email thread scenarios | | Yes (config/email-threads.json) |
| DLP policy names | | Yes (configured separately) |
| Wizard flow + Azure infra | | Yes |

### Test Results (v2.0)

Tested on Tenant A (MngEnvMCAP711732) with US locale:

| Test | Result |
| --- | --- |
| Locale loaded at runtime | `Locale loaded: US (a US company)` |
| File types from locale | `File types loaded from US locale: HR, Sales, Finance, Legal` |
| Scan image US (Pay Stub) | `Scan_Pay_Stub_2026-05-05_626.png` (18KB, SSN + Routing) |
| AI-generated US files | `Employee_Roster_2026-05-05_737.csv` |
| Agent prompt | `a US company` (not French) |
| Scan image FR | `BULLETIN DE PAIE` + NIR + IBAN FR76 |
| Scan image DE | `LOHNABRECHNUNG` + Steuer-ID + IBAN DE |
| Scan image UK | `PAYSLIP` + NI Number + Sort Code |

## M365 Collaboration (SharePoint + Teams)

Step 4a provisions the M365 infrastructure used by agents for file uploads and activity posts.

### Create vs Existing mode

At Step 4a, the wizard asks:
- **[C]reate**: Creates a new Teams team `CorpLab - Departments` with per-department channels (HR, Finance, Legal, Engineering, Sales), a backing SharePoint site with department folders, and adds all agents as members.
- **[E]xisting**: Prompts for existing SharePoint site ID and Teams group ID. Use this when you already have a site/team configured.

### How Teams channels work

The wizard resolves all channel IDs at provisioning time and stores them as an `AgentTeamsChannels` Automation variable (JSON mapping). The runbook loads this mapping at startup — **no Graph API call needed at runtime**. This avoids ROPC permission issues with `GET /teams/{id}/channels`.

## Sensitivity Labels

Step 4b creates 5 sensitivity labels via Security & Compliance PowerShell:

| Label | Scope | Visual Marking |
| --- | --- | --- |
| General | All | Light gray header |
| Confidential | All | Orange header + footer |
| Conf-HR | HR sub-label | Red header/footer |
| Conf-Finance | Finance sub-label | Blue header/footer |
| Highly Confidential | All | Red centered header/footer |

**Prerequisites**: `Connect-IPPSSession` must be authenticated before running Step 4b. The wizard detects if the session is not connected and offers auto-connect or skip.

**Propagation**: Labels take 24-48h to appear in Office apps. The runbook applies labels via Graph Beta API which works within minutes.
