# How to Start

This guide explains how to reproduce ClaudIA from zero in a clean Microsoft 365 lab tenant and Azure subscription.

If the tenant has never been configured for Microsoft 365 audit, Conditional Access, Purview, or demo users, read [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md) before running the installer.

## 1. Local Workstation

Use Windows with PowerShell 7. Run PowerShell as Administrator for the first setup.

Install these tools:

| Tool | Why it is needed |
| --- | --- |
| PowerShell 7 | Runs the installer, modules, validation, and operations scripts. |
| Azure CLI | Signs in to Azure, reads Key Vault values, configures Azure resources, and obtains Graph tokens. |
| Git | Clones and updates the repository. |
| Node.js LTS | Runs Playwright browser agents and validation scripts. |
| Microsoft Edge or Chromium | Browser automation target for Playwright tests. |
| Visual Studio Code | Optional, but useful for editing config and running GitHub Copilot assisted deployments. |

Install required PowerShell modules:

```powershell
Install-Module Az -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```

Install Node dependencies for browser agents only when you plan to run browser automation:

```powershell
cd .\BrowserAgents
npm install
npx playwright install chromium
cd ..
```

## 2. Azure And Microsoft 365 Requirements

Use a non-production lab tenant.

Minimum cloud requirements:

| Requirement | Notes |
| --- | --- |
| Azure subscription | Contributor or Owner access is recommended for the resource group used by ClaudIA. |
| Microsoft Entra ID tenant | Global Administrator or equivalent setup rights are required during initial provisioning. |
| Microsoft 365 E5 or equivalent trial/lab licenses | Needed for Purview, Defender, DLP, sensitivity labels, audit, Teams, Exchange, SharePoint, OneDrive, and optional Copilot scenarios. |
| Azure Key Vault | Stores agent and app secrets so secrets stay outside the repository. |
| Azure Automation | Runs autonomous agent jobs and operational runbooks. |
| Azure OpenAI or Azure AI Foundry | Generates synthetic business content. |
| Log Analytics and Microsoft Sentinel | Stores and analyzes generated telemetry. |
| Azure Data Explorer | Optional but recommended for storyline and activity analytics. |
| Azure Functions and Storage Static Website | Required for the activity story map portal. |
| Microsoft Playwright Testing or local Playwright | Optional browser-persona execution. |

For a completely new tenant, also validate Security Defaults, Conditional Access, audit ingestion, user creation, persona photos, and the optional Activity Portal before running the full installer.

Microsoft 365 Copilot licenses are optional for the base lab. If no Copilot licenses are available, the installer can disable only Copilot-specific runbook tasks while leaving the rest of ClaudIA active, including non-Copilot AI emulation such as ExternalAI scenarios through Azure AI Foundry.

A new Azure subscription can start completely empty. You do not need to create a resource group manually before running ClaudIA. During setup, choose a resource group name such as `rg-claudia-lab`; Step 4 creates it if it does not already exist. If your organization requires pre-created resource groups, create it first and enter that name in the wizard.

Do not paste the Azure subscription ID into the resource group field. The subscription ID is a GUID such as `11111111-1111-1111-1111-111111111111`; the resource group is a name such as `rg-claudia-lab`.

If the Azure subscription is owned by an account from another organization, the account must also exist in the demo tenant and have Azure RBAC on the subscription. Invite the account as an external user in Microsoft Entra ID, have the user accept the invitation, and assign Owner or Contributor on the target subscription or resource group before running the installer.

For the simplest deployment, use one account that has both:

| Plane | Required access |
| --- | --- |
| Azure | Owner or Contributor on the target subscription or resource group. |
| Microsoft 365 / Entra | Global Administrator or Privileged Role Administrator for first setup. |

An Azure `Account admin` or subscription owner from another tenant is not automatically a Microsoft 365 administrator in the demo tenant. If the subscription was created in another directory, move or associate the subscription with the demo tenant before setup so it appears under the target tenant during `az login --tenant <tenant-domain>`.

If your organization separates Azure administration from Microsoft 365 administration, ClaudIA can prompt for a separate Microsoft 365/Entra admin sign-in. The installer keeps this sign-in in an isolated local Azure CLI profile under `.claudia/az-m365-admin` so the Azure subscription sign-in remains active for Azure resource deployment. Do not commit the `.claudia` folder.

Register providers before deployment:

```powershell
az provider register -n Microsoft.CognitiveServices --wait
az provider register -n Microsoft.Automation --wait
az provider register -n Microsoft.KeyVault --wait
az provider register -n Microsoft.OperationalInsights --wait
az provider register -n Microsoft.Kusto --wait
az provider register -n Microsoft.Web --wait
az provider register -n Microsoft.Storage --wait
```

For a new subscription, the installer can also trigger provider registration during prerequisite checks:

```powershell
.\Install-ClaudIA.ps1 -RegisterProviders
```

## 3. Clone And Prepare

Preferred source:

```powershell
git clone https://github.com/MH-Demos/ClaudIA.git ClaudIA
cd ClaudIA

Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

If the GitHub repository is private or not accessible yet, use the local synchronized folder provided by the project owner:

```powershell
cd C:\MyDev\ClaudIA
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

Do not run validation from an older working copy such as `purview-autonomous-agents-master\M365-Autonomous-IA` unless you intentionally want to validate that legacy version.

Do not download only `Install-ClaudIA.ps1`. The installer depends on the full repository structure, including `modules`, `config`, `tools`, `prerequisites`, `Images`, and documentation files.

To update only ClaudIA PowerShell scripts without replacing local tenant configuration, use the script updater:

```powershell
.\tools\Update-ClaudIAScripts.ps1
```

The updater reads `UpdateInfo/update.json`, compares each script's `PSScriptInfo` version, backs up changed local scripts under `BackupScripts`, and downloads newer scripts from GitHub. The manifest intentionally excludes tenant configuration and generated files.

If you plan to download or replace the full repository folder, back up local configuration first:

```powershell
.\tools\Backup-ClaudIAConfiguration.ps1
```

After replacing the repository files, restore the latest configuration backup:

```powershell
.\tools\Backup-ClaudIAConfiguration.ps1 -Mode Restore
```

Backups are stored under `TemporaryBackup` and preserve the original folder structure. After validating the restored environment, you can delete `TemporaryBackup`.

If PowerShell shows a message like `is not digitally signed` or `cannot be loaded`, unblock the downloaded scripts from the repository root:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
```

Then run:

```powershell
.\Install-ClaudIA.ps1
```

## 4. Configure The Lab

Start from [config/agents.json](config/agents.json). Replace public placeholders with your lab values:

| Field | Replace with |
| --- | --- |
| `tenant.domain` | Your lab tenant domain, for example `contoso.onmicrosoft.com`. |
| `tenant.tenantId` | Your Entra tenant ID. |
| `tenant.subscriptionId` | Your Azure subscription ID. |
| `infrastructure.resourceGroup` | Resource group for ClaudIA. |
| `infrastructure.keyVaultName` | Your Key Vault name. |
| `infrastructure.openAiAccountName` | Your Azure OpenAI account or deployment host. |
| `infrastructure.openAiImageModel` | Optional image model. The default is `Dall-e-3`; keep it unless you know your region uses a different model name. |
| `adx.*` | Your ADX cluster, database, table, and app identity values if ADX is enabled. |
| `activityStoryMap.*` | Your storage, function app, API, and optional Front Door values. |
| `agents[*].userPrincipalName` | Persona users in your lab tenant. |

Do not write passwords, client secrets, access tokens, connection strings, or browser storage states into JSON files.

Use Key Vault for secrets:

```powershell
az keyvault secret set --vault-name kv-claudia-lab --name agent-client-secret --value "<client-secret>"
az keyvault secret set --vault-name kv-claudia-lab --name priya-sharma --value "<persona-password>"
```

## 5. Sign In And Validate

```powershell
az logout
az login --tenant contoso.onmicrosoft.com
az account set --subscription 11111111-1111-1111-1111-111111111111

.\prerequisites\Test-Prerequisites.ps1
.\tools\Test-PublicRepoSafety.ps1
```

Fix all prerequisite failures before running the installer.

If you manage several tenants, always start with a fresh Azure CLI session for the demo tenant. The installer also offers to clear cached Azure CLI sessions and sign in again after you enter the tenant domain. This prevents subscriptions from unrelated tenants from appearing in the selection list.

If Azure CLI says the selected account does not exist in the tenant, use a different account from the target tenant or invite the external account into the tenant first. If `az login` succeeds but shows no subscriptions, assign Azure RBAC to that signed-in account, then run the installer again.

If prerequisites report that the deploying user has no admin directory role, Step 1 has not run yet. That is intentional: ClaudIA cannot create users, assign licenses, create the ROPC app, or grant consent until the signed-in account has tenant admin rights.

When prompted, sign in with a separate Global Administrator or Privileged Role Administrator if the Azure subscription account is not also a Microsoft 365 admin.

## 6. Deploy Core ClaudIA

Run the wizard:

```powershell
.\Install-ClaudIA.ps1
```

Expected deployment areas:

| Area | Result |
| --- | --- |
| Entra personas | Lab users or selected existing users configured for autonomous activity. |
| Microsoft 365 workloads | SharePoint, OneDrive, Outlook, Teams, and optional Fabric targets. |
| Purview | Sensitivity labels, DLP policies, Insider Risk and DSPM-related scenarios where available. |
| Azure | Automation, Key Vault, OpenAI, Log Analytics, Sentinel, ADX, storage, Functions, and optional Front Door. |
| Runbooks | Scheduled agent execution and supporting operational tasks. |

If Copilot licenses are added later, re-enable Copilot tasks:

```powershell
.\tools\Set-CopilotTasks.ps1 -Mode Enable
.\tools\Publish-RunbookOnly.ps1
```

The wizard is designed to be re-run safely. Use dry run mode before changes when needed:

```powershell
.\Install-ClaudIA.ps1 -DryRun
```

## 7. Run A Smoke Test

```powershell
.\tests\Test-SingleAgent.ps1 -Agent priya.sharma
.\Manage-Costs.ps1 -Action Status
```

For browser automation:

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent priya.sharma -Services owa
```

Browser sessions are stored under `BrowserAgents/.auth` and are intentionally ignored by Git.

## 8. Reproduce The Storyline

Use these assets in order:

1. Read [Storyline/profiles.md](Storyline/profiles.md) to understand personas.
2. Review [Storyline/live_demo_runbook_defender_purview.md](Storyline/live_demo_runbook_defender_purview.md) for the demo flow.
3. Use [Storyline/banking-finance-e5-activity-scenarios](Storyline/banking-finance-e5-activity-scenarios) for deeper scenario packs.
4. Publish or run [activity-story-map/web](activity-story-map/web) to show the visual portal.
5. Keep [Images](Images) aligned with persona and service references.

When adding a new scenario, update the storyline, config, relevant scripts, and README links together.

## Optional: Activity Portal, Photos, And Branding

The Activity Portal is optional. Add it when the demo should include a public visual map, persona images, service icons, branding, and storyline navigation.

For a new tenant:

```powershell
.\tools\Set-EntraUserPhotos.ps1 -WhatIf
.\tools\Set-EntraUserPhotos.ps1
.\tools\Publish-ActivityStoryMapAssets.ps1
```

The installer also offers to upload persona photos after Step 1 creates or selects users. If you skip that prompt, run it later:

```powershell
.\tools\Set-EntraUserPhotos.ps1 -SkipMissing
```

Branding is driven by file names under `Images/Branding`, `Images/Characters`, and `Images/Services`. Replace images, keep names aligned with personas and services, then republish the Activity Portal assets.

## 9. Keep The Repo Public-Safe

Before pushing:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

Do not commit generated folders:

- `BrowserAgents/.auth`
- `BrowserAgents/node_modules`
- `BrowserAgents/playwright-report`
- `BrowserAgents/test-results`
- `logs`
- `out`
- `.env`
- `temp_*.json`
