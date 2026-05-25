# PAYG and Licensing Tracker

This document tracks which services in this lab are pay-as-you-go, which ones are covered by existing Microsoft 365 licensing, and which ones are using low-cost or free-tier Azure resources where available.

## Immediate Finding

The `paymentRequired` error raised by the runbook comes from Microsoft Graph when calling:

```text
POST /sites/{site-id}/drive/items/{item-id}/assignSensitivityLabel
```

That endpoint is the SharePoint and OneDrive for Business `assignSensitivityLabel` API. Microsoft documents it as a protected, metered Microsoft Graph API. The app registration that calls it must be associated with an Azure subscription through a `Microsoft.GraphServices/accounts` resource before the API can be used.

In this lab, the calling app is `app-dataagent`, stored in config as:

```json
adx.clientId
```

or, depending on the installation stage:

```json
application.clientId
```

Current lab billing resource:

| Field | Value |
| --- | --- |
| Subscription | `ab97362c-5d5f-49a5-bf87-c8480e54e062` |
| Resource group | `MH-Agents-PAYG` |
| Resource name | `graph-metered-app-dataagent` |
| Resource type | `Microsoft.GraphServices/accounts` |
| Location | `global` |
| App ID | `22222222-2222-2222-2222-222222222222` |
| Provisioning state | `Succeeded` |
| Billing plan ID | `bdec0477-8c65-40ff-a6b5-693302a13f22` |

## PAYG Services

| Service | Why We Use It | Billing Model | Current Status | Notes |
| --- | --- | --- | --- | --- |
| Microsoft Graph metered APIs: SharePoint/OneDrive `assignSensitivityLabel` | Applies sensitivity labels to files at rest from the runbook | Metered per API call | Required for automatic label application through Graph | Enable by creating `Microsoft.GraphServices/accounts` linked to `app-dataagent` |
| Azure OpenAI | Generates realistic business documents, emails, and prompts | Token/model usage | Required | Cost depends on selected model, region, and quota |
| Azure AI Foundry model deployments | Optional external AI simulation with non-Copilot model families | Token/model usage | Optional | Used by expansion scenarios such as ExternalAI |
| Azure Data Explorer | Stores lab telemetry from the runbook and story map | Cluster/runtime + storage | Required for current telemetry architecture | Dev/Test SKU can reduce cost; streaming ingestion is enabled |
| Azure Automation | Runs the autonomous agent runbook | Job runtime and account features | Required | Usually small cost for this lab |
| Azure Key Vault | Stores app and agent secrets | Operations + storage | Required | Standard tier is enough for current use |
| Azure Storage / Static Web Apps or storage static website | Hosts optional story map assets and function storage | Storage, transactions, bandwidth | Optional | Depends on Activity Story Map deployment |
| Azure Front Door | Optional custom domain/front door for Activity Story Map | Routing/rules/requests | Optional | Only needed for polished public demo URL |

## Services Usually Covered by Microsoft 365 Licensing

| Service | Why We Use It | License Dependency | Notes |
| --- | --- | --- | --- |
| Exchange Online | Sends and receives agent emails | Microsoft 365 mailbox license | Required for email scenarios |
| SharePoint Online / OneDrive | Stores generated files and collaboration artifacts | Microsoft 365 license with SharePoint/OneDrive | Required for file and DLP scenarios |
| Microsoft Teams | Posts department messages and thread activity | Microsoft 365 license with Teams | Required for Teams workloads |
| Microsoft Purview DLP | Generates DLP policy matches and Activity Explorer events | Microsoft 365 E5, E5 Compliance, or equivalent Purview entitlement | Exact entitlement depends on tenant SKU |
| Microsoft Purview sensitivity labels | Label policy publishing, Activity Explorer visibility | Microsoft 365 E5, E5 Compliance, or equivalent Purview entitlement | Applying labels via Graph still needs the metered API setup above |
| Microsoft 365 Copilot | Copilot-style agent scenarios and search prompts | Microsoft 365 Copilot license for selected users | Optional; only assigned to configured Copilot agents |
| Activity Explorer | Visibility for audited Purview activities | Purview audit/compliance entitlement | Events can take time to appear after activity occurs |

## Free Tier or Low-Cost Azure Usage

| Service | Usage | Cost Control |
| --- | --- | --- |
| Azure Data Explorer Dev/Test SKU | Lab telemetry table | Use the smallest supported SKU, monitor cluster runtime, stop/delete when not used |
| Azure Key Vault Standard | Secrets for app and agent credentials | Standard tier; avoid Premium unless required |
| Azure Automation runbooks | Agent jobs | Keep schedules reasonable; avoid high-frequency test loops |
| Azure Storage | Static assets, generated site content, function storage | Lifecycle/delete old artifacts when no longer needed |

## Enable Graph Metered API Billing

Use an Azure subscription in the same tenant as the `app-dataagent` application registration.

The project includes an automation helper:

```powershell
.\tools\Enable-GraphMeteredBilling.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<resource-group>'
```

The script resolves the `app-dataagent` AppId from configuration, creates or reuses the resource group, registers `Microsoft.GraphServices`, creates the `Microsoft.GraphServices/accounts` resource, waits for provider registration, and validates the linked app id.

Manual equivalent:

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroup = '<resource-group>'
$appId = '<app-dataagent-client-id>'
$billingResourceName = 'graph-metered-app-dataagent'

az account set --subscription $subscriptionId
az provider register --namespace Microsoft.GraphServices

az graph-services account create `
  --resource-group $resourceGroup `
  --resource-name $billingResourceName `
  --subscription $subscriptionId `
  --location global `
  --app-id $appId
```

Verify:

```powershell
az resource list --resource-type Microsoft.GraphServices/accounts -o table

az resource show `
  --resource-group $resourceGroup `
  --name $billingResourceName `
  --resource-type Microsoft.GraphServices/accounts
```

After enabling it, request a new OAuth token before testing label application again. In practice, republishing/rerunning the runbook is enough because each run obtains fresh tokens.

## Current ADX Note

The runbook successfully writes file operation telemetry as:

```text
ActivityType = activity_explorer
Action = FileRead | DownloadFile | UploadText | FileCreated | FileModified | FileRenamed | FileDeleted
ActivityExplorerTarget = true
```

If `Test-SingleAgent.ps1 -Services fileops` reports no ADX data while `tools\Get-ActivityExplorerFileOps.ps1` shows rows, the issue is the test filter, not ingestion. The test should expand `fileops` to `activity_explorer` and the file operation action names.

## Label-Supported File Formats

After Graph metered billing is enabled, a remaining `unsupportedMediaType` error means the API is reachable, but the file extension is not supported for `assignSensitivityLabel`.

For the Activity Explorer and sensitivity-label path, the runbook should prefer:

| Format | Usage |
| --- | --- |
| `.docx` | Narrative documents, reports, employee files, legal memos, converted text/Markdown/JSON/HTML scans |
| `.xlsx` | Tabular data converted from CSV-like content |
| `.pptx` | Presentation-style activities, future enhancement |
| `.pdf` | Uploaded PDFs when supported by SharePoint/OneDrive labeling configuration |
| Email | Sensitivity labels through Exchange/Outlook scenarios, not through driveItem labeling |

The runbook now converts unsupported text-like files to `.docx` and CSV-like files to `.xlsx` when running Purview/Activity Explorer-focused tests such as:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez -Services fileops
```

## Activity Explorer Actor Attribution

When the runbook applies a label with Microsoft Graph:

```text
POST /sites/{site-id}/drive/items/{item-id}/assignSensitivityLabel
```

the label is applied by the SharePoint/OneDrive service pipeline. In Activity Explorer this can appear as:

```text
User: SHAREPOINT\system
Activity: Label applied
Label event type: LabelUpgraded
How applied: None
```

This is expected for the current Graph-driven baseline labeling path. It is useful to prove labeling, PAYG metered API setup, and Purview processing, but it is not ideal as the main demo story because the visible actor is the service, not the simulated employee.

For a user-attributed demo, use one of these paths:

| Path | Expected Activity Explorer actor | Complexity | Notes |
| --- | --- | --- | --- |
| Office web or desktop user session applies/saves labels | The signed-in user | Medium/High | Best demo fidelity. Requires browser/Office automation or guided manual action. |
| Microsoft Purview Information Protection client / file labeler on a Hybrid Runbook Worker or endpoint VM | The configured user/service context | High | Good for endpoint-style demos and file operations. Requires Windows endpoint setup. |
| Endpoint DLP on onboarded Windows 11 / Windows 365 Cloud PC | The signed-in user and device | High | Required for print, clipboard, removable media, network share, browser upload, screen capture, and similar user/device actions. |
| Graph `assignSensitivityLabel` from Azure Automation | `SHAREPOINT\system` | Low | Good for baseline labels, not for user-attributed Activity Explorer screenshots. |

Recommended demo design:

1. Keep Graph labeling enabled to seed labeled files quickly.
2. Add a small set of human-looking actions from Office web/desktop or an onboarded endpoint for screenshots where the `User` field matters.
3. Use ADX/story map to show the broader synthetic narrative, and Activity Explorer to show the highest-fidelity user/device moments.

## References

- Microsoft Graph: Enable metered APIs and services: https://learn.microsoft.com/en-us/graph/metered-api-setup
- Microsoft Graph: Metered APIs and services list: https://learn.microsoft.com/en-us/graph/metered-api-list
- Microsoft Graph: driveItem assignSensitivityLabel: https://learn.microsoft.com/en-us/graph/api/driveitem-assignsensitivitylabel
- Microsoft Purview: Activity Explorer: https://learn.microsoft.com/en-us/purview/data-classification-activity-explorer
- Microsoft Purview: Labeling activities available in Activity Explorer: https://learn.microsoft.com/en-us/azure/information-protection/audit-logs
