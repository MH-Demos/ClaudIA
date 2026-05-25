# If Your Tenant Is Completely New

Use this guide when the Microsoft 365 tenant has never hosted ClaudIA before. A brand-new tenant usually needs identity, audit, licensing, security, and portal decisions before the installer can create a working environment.

## Safe Access Model

Do not share credentials, passwords, client secrets, refresh tokens, or exported browser sessions in chat, Git, screenshots, or documentation.

Recommended validation model:

1. Sign in locally with an administrator account:

   ```powershell
   az logout
   az login --tenant contoso.onmicrosoft.com
   az account set --subscription 11111111-1111-1111-1111-111111111111
   ```

2. Run ClaudIA checks and scripts from the authenticated workstation.
3. Store generated secrets in Azure Key Vault or Automation encrypted variables.
4. Keep `.env`, `BrowserAgents/.auth`, logs, and generated output outside Git.

## Source Folder

Use the GitHub repository when available:

```powershell
git clone https://github.com/MH-Demos/ClaudIA.git C:\MyDev\ClaudIA
cd C:\MyDev\ClaudIA
```

If the repository is private or not accessible, use the local synchronized copy:

```powershell
cd C:\MyDev\ClaudIA
```

Do not modify or run validation from an older functional folder such as `purview-autonomous-agents-master\M365-Autonomous-IA` unless you are intentionally testing that older implementation.

## New Tenant Decision Checklist

| Decision | Why it matters |
| --- | --- |
| Create demo users or use existing users | A clean public demo should normally create dedicated synthetic Entra users. |
| Disable Security Defaults and use Conditional Access | Browser and ROPC-based lab agents cannot pass mandatory MFA. Use a scoped CA policy with a dedicated exclusion group for lab agents only. |
| Enable audit ingestion | Purview, Defender, and Activity Explorer scenarios depend on audit activity being available. |
| Assign Microsoft 365 licenses | Users need Exchange, SharePoint, OneDrive, Teams, Purview, and optional Copilot capabilities. |
| Deploy Activity Portal | Optional, but recommended when the demo needs public storytelling, architecture navigation, images, and activity visualization. |
| Upload persona photos | Optional, but useful for Teams, Outlook, portal screenshots, and storyline recognition. |
| Choose branding | Branding can be changed by replacing files in `Images/Branding` and republishing the Activity Portal assets. |

## 1. Validate Admin And Subscription Access

The setup account should have:

| Scope | Recommended role |
| --- | --- |
| Microsoft Entra ID | Global Administrator for initial setup, or a combination of User Administrator, Application Administrator, Groups Administrator, and Conditional Access Administrator. |
| Microsoft 365 workloads | Exchange, SharePoint, Teams, and Purview admin rights as needed by enabled modules. |
| Azure subscription | Owner or Contributor on the target subscription or resource group. |
| Azure Key Vault | Key Vault Administrator or Secrets Officer during setup. |

For the easiest first deployment, use the same account for both the Azure and Microsoft 365 sides. That account should be able to deploy Azure resources and administer the target tenant.

If Azure and Microsoft 365 are administered by different people, use the installer prompt to sign in with a separate Microsoft 365/Entra admin account. ClaudIA stores that second sign-in in a local isolated Azure CLI profile under `.claudia/az-m365-admin`, while the original Azure account remains available for subscription and resource group deployment.

If the subscription owner account is from a different tenant or organization, add that account to the demo tenant first:

1. Invite the account as an external user in Microsoft Entra ID.
2. Have the user accept the invitation.
3. Assign Owner or Contributor on the target Azure subscription or on the ClaudIA resource group.
4. Sign in with `az login --tenant contoso.onmicrosoft.com` and confirm the subscription is visible.

Being able to sign in to Azure is not enough. The signed-in account must both exist in the target Entra tenant and have Azure RBAC on the subscription that ClaudIA will deploy to.

If the subscription was created under another directory, change the subscription directory to the demo tenant before installation. Otherwise `az login --tenant <demo-tenant>` can succeed while `az account list` still shows no usable subscription.

Run:

```powershell
az account show --query "{tenant:tenantId, subscription:id, name:name}" -o table
.\prerequisites\Test-Prerequisites.ps1 -RegisterProviders
```

If the Azure subscription is brand new, it may not contain any resource groups. That is expected. ClaudIA asks for a resource group name and creates it during Azure infrastructure deployment. If your environment already has an approved resource group, enter that existing name instead.

Use a resource group name such as `rg-claudia-lab`. Do not paste the subscription ID into the resource group prompt. A subscription ID is a GUID; a resource group is a human-readable Azure container name.

If the workstation has been used with several tenants, clear the Azure CLI cache before setup:

```powershell
az logout
az login --tenant contoso.onmicrosoft.com
az account list -o table
```

Only subscriptions from the target tenant should be selected. During interactive setup, ClaudIA offers to sign out from cached Azure CLI sessions and sign in to the tenant domain you entered.

If Azure CLI returns `Selected user account does not exist in tenant`, the account was not yet accepted into the target tenant. Invite it as an external user or use a native target-tenant admin account. If Azure CLI returns `No subscriptions found`, assign Azure RBAC to that account and retry before continuing.

For a brand-new subscription, register Azure providers before deployment or run the installer with provider registration enabled:

```powershell
.\Install-ClaudIA.ps1 -RegisterProviders
```

The installer stops before Step 1 when prerequisites fail. If you see provider or admin-role failures, user creation has not started yet; fix those items first, then rerun the installer.

## 2. Security Defaults And Conditional Access

Brand-new Entra tenants may have Security Defaults enabled. Security Defaults is good for real tenants, but it conflicts with this lab pattern because synthetic autonomous users cannot satisfy MFA in unattended ROPC and scheduled browser workflows.

For a ClaudIA lab tenant:

1. Confirm this is not a production tenant.
2. Disable Security Defaults.
3. Create a dedicated group for ClaudIA agent MFA exclusion, for example `grp-claudia-agent-mfa-exclusion`.
4. Create a Conditional Access policy that requires MFA for normal users.
5. Exclude only the dedicated ClaudIA agent group.
6. Never assign admin roles to excluded agent accounts.

This is a lab-only exception. If an agent receives any privileged role, remove it from the MFA exclusion group immediately.

## 3. Audit Readiness

ClaudIA needs Microsoft 365 audit signals for Activity Explorer, Purview, Defender, and storyline validation. In a new tenant, verify audit ingestion before expecting demo events to appear.

Recommended checks:

```powershell
Connect-ExchangeOnline
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled
```

If audit ingestion is disabled in the lab tenant, enable it:

```powershell
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```

Audit availability can take time after first enablement, licensing, or workload activation. Plan a warm-up period before a live demo.

## 4. Create Demo Users In Entra

For public repeatability, prefer dedicated synthetic users created from [config/agents.json](config/agents.json). The installer can create or detect users, assign workload context, and store credentials through the configured secret flow.

Before deployment, decide:

- Tenant domain for all persona UPNs.
- Password handling model.
- License SKUs to assign.
- Whether all personas are required for the first demo or only a minimum wave.

Run:

```powershell
.\Install-ClaudIA.ps1 -DryRun
```

Then run the full installer when the dry run looks correct:

```powershell
.\Install-ClaudIA.ps1
```

## 5. Upload Persona Pictures

Persona images are stored in [Images/Characters](Images/Characters). The easiest convention is:

```text
Images/Characters/Priya Sharma.png
Images/Characters/Marcus Olsson.png
Images/Characters/Devon Reyes.png
```

The file base name should match `displayName` in [config/agents.json](config/agents.json). Validate mappings first:

```powershell
.\tools\Set-EntraUserPhotos.ps1 -WhatIf
```

Upload photos:

```powershell
.\tools\Set-EntraUserPhotos.ps1
```

The script uses the current Azure CLI session to call Microsoft Graph. The signed-in account must be allowed to update user profile photos.

## 6. Activity Portal Decision

Ask this before deployment:

> Do you want to add the Activity Portal?

Choose **yes** when you want a public-facing visual portal for architecture, storylines, personas, images, service icons, and activity maps. Choose **no** for a minimal automation-only lab.

If enabled, configure:

| Config area | Purpose |
| --- | --- |
| `activityStoryMap.enabled` | Turns the portal deployment path on or off. |
| `activityStoryMap.storageAccountName` | Hosts the static website. |
| `activityStoryMap.functionAppName` | Hosts the API. |
| `activityStoryMap.apiBaseUrl` | Lets the web portal call the API. |
| `activityStoryMap.frontDoor` | Optional custom domain and cache layer. |

Deploy or refresh:

```powershell
.\modules\Deploy-ActivityStoryMap.ps1
.\tools\Publish-ActivityStoryMapAssets.ps1
```

## 7. Branding By File Names

Branding is file-based. Replace or add files under:

```text
Images/Branding
Images/Characters
Images/Services
```

Then republish:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1 -PurgeFrontDoor
```

The publisher builds `activity-story-map/web/images/manifest.json` from file names. For predictable matching:

- Character image names should match persona display names.
- Service icon names should match the service name used in the story map.
- Branding image names become manifest keys after lowercasing and punctuation normalization.

## 8. Minimum New-Tenant Validation

Before declaring the environment ready:

```powershell
.\tools\Test-PublicRepoSafety.ps1
.\prerequisites\Test-Prerequisites.ps1
.\Install-ClaudIA.ps1 -DryRun
.\tests\Test-SingleAgent.ps1 -Agent priya.sharma
```

Then validate in the portals:

| Portal | What to check |
| --- | --- |
| Entra admin center | ClaudIA users exist, are licensed, and are not administrators. |
| Entra Conditional Access | MFA exclusion is scoped only to the ClaudIA agent group. |
| Purview | Audit, Activity Explorer, DLP, labels, and Insider Risk scenarios are visible where licensed. |
| Exchange and SharePoint | Mailboxes, OneDrive, SharePoint sites, and Teams resources are provisioned. |
| Azure Portal | Key Vault, Automation, OpenAI, Log Analytics, Sentinel, ADX, Function App, and Storage are deployed as configured. |
| Activity Portal | Images, branding, personas, and activity data load correctly if the portal is enabled. |
