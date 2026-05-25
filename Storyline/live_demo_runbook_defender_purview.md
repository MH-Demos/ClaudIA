# Live demo runbook - Defender, Purview and Copilot

Target date: Wednesday, 2026-05-27
Audience: in-person public security workshop
Tenant: contoso.example

## Objective

Show a visible end-to-end security story:

1. Sensitive business documents exist in Microsoft 365.
2. Priya Sharma, as a data scientist with Copilot, can discover overshared content that is relevant to her analytics work.
3. Purview classifies, labels, and raises DLP/DSPM signals.
4. Defender XDR and Advanced Hunting provide investigation evidence.
5. Sentinel receives the security story for SIEM/SOAR visibility.
6. Entra ID and permissions explain why Copilot finds the content: Copilot inherits access, it does not create new access.

## Storyline

Priya is preparing a workforce and revenue correlation model. She asks Copilot for workforce planning, executive risk, legal AI guidance, and operational capacity documents. Copilot surfaces documents owned by Alexander, Emily, James, and Marcus because they are overshared or stored in collaboration areas where Priya has access.

This creates a clean narrative for the PDF section:

- "AI is powerful, but without data governance it becomes a data exposure accelerator."
- "Copilot respects permissions, labels, and policies."
- "The security team needs Purview, Defender, Sentinel, and Entra together."

## One-week preparation plan

### 2026-05-20 to 2026-05-22: seed content

Use the synthetic document pack in `content-library/live-demo/`. Install the dedicated Teams-backed SharePoint site as an expansion pack, not as part of the base installer:

```powershell
.\tools\Install-LiveDemoMay272026ExpansionPack.ps1
```

If you need to re-upload the seed content manually later, use the helper with the site URL created by the expansion pack:

```powershell
.\tools\Publish-LiveDemoSeedContent.ps1 -SiteUrl "https://contoso.sharepoint.com/sites/LiveDemoMay272026" -RootFolder "Purview-Defender-SeedContent"
```

Use `-WhatIf` first if you want to preview the upload paths.

Recommended placement:

| Document | Suggested owner | Suggested location | Demo purpose |
| --- | --- | --- | --- |
| `2026-05-18_Alexander_board_restructuring_notes_confidential.md` | Alexander Meyer | Executive AI Risk / AI Governance | Executive strategy surfaced by Copilot |
| `2026-05-19_Emily_ai_data_use_legal_memo_confidential.md` | Emily Johnson | Operations Legal AI / Case Review | Legal review with sensitive examples |
| `2026-05-19_James_operations_capacity_risk_q3.md` | James Wilson | Operations Legal AI / Data Requests | Operations context linked to HR and finance |
| `2026-05-20_Marcus_dlp_triage_shadow_ai.md` | Marcus Olsson | Security Shadow AI / Leak Investigations | Security triage and DLP/Sentinel handoff |
| `2026-05-20_Workforce_Planning_Draft_overshared.csv` | Laura Gomez or Alexander Meyer | OneDrive draft shared broadly | Oversharing trigger |
| `2026-05-20_Priya_model_feature_inventory_sensitive.csv` | Priya Sharma | Data science workspace | Justifies Priya's Copilot queries |

Keep all documents synthetic. They intentionally contain fake SSN, routing/account, EIN, phone, email, and salary-like values so Purview SIT detection has material to work with.

### 2026-05-23 to 2026-05-25: let signals mature

Run the autonomous agents at least once per day:

```powershell
.\tools\Publish-RunbookOnly.ps1
.\tools\Get-RunbookStatus.ps1
```

In Azure Automation, run `Invoke-AgentRunbook` with:

```text
RunAsAgent: priya.sharma
SendEmails: True
SkipWeekendCheck: True
ActivityMode: burst
ServiceFilter: meetings,copilot,email
```

Then run broader activity:

```text
RunAsAgent: 
SendEmails: True
SkipWeekendCheck: True
ActivityMode: full
ServiceFilter: spo,teams,mail,copilot,external ai
```

### 2026-05-26: verify evidence

Purview:

- Data Classification > Content Explorer: confirm SSN, routing/account, EIN, and credit card SIT hits.
- Activity Explorer: filter by Priya, Alexander, Emily, James, Marcus.
- DLP alerts: confirm policy matches for SharePoint, OneDrive, Teams, Copilot, and Endpoint if enabled.
- DSPM for AI: confirm overshared sensitive content and AI usage findings.

Defender:

- Incidents and alerts: confirm DLP or risky activity signals appear.
- Advanced Hunting: run the queries in this runbook and save them as browser favorites or query tabs.

Sentinel:

- Confirm Microsoft 365 Defender connector is connected.
- Confirm Microsoft Purview / OfficeActivity ingestion path is available.
- Confirm the workspace has at least one workbook or analytic rule visible for the demo.

### 2026-05-27: live flow

1. Open the PDF context with the message: "La IA es poderosa... pero sin gobierno de datos es un riesgo."
2. In Windows 365 as Priya, open Copilot and run the prepared prompts.
3. Show that Copilot returns documents related to Alexander, Emily, James, or Marcus.
4. Open the surfaced document and point out sensitivity labels or visible sensitive fields.
5. Switch to Purview Activity Explorer / DLP alerts and show the policy evidence.
6. Switch to Defender Advanced Hunting and show the search/audit traces.
7. Switch to Sentinel and show the same story as a SOC-oriented view.
8. Close with Entra ID: Priya found the documents because access allowed it, not because Copilot bypassed security.

## Priya Copilot prompts

Use these from the Windows 365 machine:

```text
Find workforce planning drafts that mention restructuring, compensation, or social security number data and summarize the risks for a data science model.
```

```text
Look for executive AI risk or board readiness notes involving Alexander Meyer, workforce planning, revenue forecast, and confidential data.
```

```text
Find legal guidance from Emily Johnson about using employee or customer data in AI prompts. Include any references to SSN, bank routing, or account numbers.
```

```text
Find operations documents from James Wilson that combine capacity risk, customer commitments, and sensitive workforce planning fields.
```

```text
Find Marcus Olsson security triage notes about DLP, shadow AI, Copilot oversharing, or Sentinel escalation.
```

## Defender Advanced Hunting queries

Use these as starting points. Table availability depends on connectors and licensing in the tenant.

### Copilot and Microsoft Search style activity

```kusto
CloudAppEvents
| where Timestamp > ago(7d)
| where AccountUpn =~ "priya.sharma@contoso.example"
| where Application has_any ("Microsoft 365 Copilot", "Microsoft Search", "SharePoint", "OneDrive")
| project Timestamp, AccountUpn, Application, ActionType, ObjectName, RawEventData
| order by Timestamp desc
```

### File access around seeded documents

```kusto
CloudAppEvents
| where Timestamp > ago(7d)
| where ObjectName has_any ("Workforce_Planning", "Alexander_board", "Emily_ai_data", "James_operations", "Marcus_dlp")
| project Timestamp, AccountUpn, Application, ActionType, ObjectName, IPAddress, DeviceType
| order by Timestamp desc
```

### Sensitive content movement in Microsoft 365 audit

```kusto
CloudAppEvents
| where Timestamp > ago(7d)
| where Application in~ ("SharePoint Online", "OneDrive for Business", "Microsoft Teams")
| where ActionType has_any ("FileAccessed", "FileDownloaded", "FileUploaded", "SharingSet", "AddedToSecureLink")
| where AccountUpn in~ ("priya.sharma@contoso.example", "alexander.meyer@contoso.example", "emily.johnson@contoso.example", "james.wilson@contoso.example", "marcus.olsson@contoso.example")
| project Timestamp, AccountUpn, Application, ActionType, ObjectName, SiteUrl, IPAddress
| order by Timestamp desc
```

### Endpoint DLP visible from the Windows 365 machine

```kusto
DeviceEvents
| where Timestamp > ago(7d)
| where DeviceName has_any ("CPC", "W365", "PRIYA")
| where ActionType has_any ("SensitiveFileRead", "SensitiveFileCopied", "FileCreated", "FileRenamed", "ClipboardSensitiveData")
| project Timestamp, DeviceName, InitiatingProcessAccountUpn, ActionType, FileName, FolderPath, AdditionalFields
| order by Timestamp desc
```

### Defender incident pivot

```kusto
AlertInfo
| where Timestamp > ago(7d)
| where Title has_any ("DLP", "data loss", "sensitive", "Copilot", "shadow AI", "exfiltration")
| join kind=leftouter AlertEvidence on AlertId
| project Timestamp, Title, Severity, Category, EntityType, EvidenceRole, AccountUpn, FileName, RemoteUrl
| order by Timestamp desc
```

## Sentinel setup checklist

Minimum viable demo:

- Enable Microsoft Sentinel on the Log Analytics workspace used by the lab.
- Connect Microsoft 365 Defender.
- Connect Microsoft Entra ID audit/sign-in logs if available.
- Connect Office 365 audit logs if not already flowing through Defender.
- Add one analytic rule named `Priya Copilot Sensitive Discovery`.

Suggested Sentinel analytic rule query:

```kusto
CloudAppEvents
| where Timestamp > ago(1d)
| where AccountUpn =~ "priya.sharma@contoso.example"
| where ObjectName has_any ("Workforce_Planning", "Alexander_board", "Emily_ai_data", "James_operations", "Marcus_dlp")
| summarize Events=count(), FirstSeen=min(Timestamp), LastSeen=max(Timestamp), Files=make_set(ObjectName, 10) by AccountUpn, Application
| where Events >= 2
```

Entity mappings:

- Account: `AccountUpn`
- Cloud application: `Application`

## Visible proof matrix

| Claim | Where to prove it | Evidence to show |
| --- | --- | --- |
| Copilot respects permissions | Entra ID / SharePoint permissions | Priya has access to the location |
| Sensitive content exists | Purview Content Explorer | SIT matches in seeded documents |
| Data is governed | Purview labels and DLP | Label and DLP policy match |
| User behavior is investigable | Defender Advanced Hunting | Priya access/search activity |
| SOC can operationalize it | Sentinel | Incident or analytic rule result |
| Remediation is clear | SharePoint / Purview / Entra | Remove broad sharing, apply label, restrict group |

## Remediation talking points

- Reduce oversharing before deploying Copilot broadly.
- Use sensitivity labels and DLP as policy guardrails.
- Use DSPM for AI to identify data that AI can surface.
- Use Defender XDR to investigate identity, device, app, and data signals together.
- Use Sentinel when the SOC needs cross-source correlation, retention, automation, and incident workflows.
