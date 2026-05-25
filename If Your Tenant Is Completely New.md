# If Your Tenant Is Completely New

Use this guide when the Microsoft 365 tenant has never hosted ClaudIA before. A brand-new tenant usually needs identity, audit, licensing, security, and portal decisions before the installer can create a working environment.

## Safe Access Model

Do not share credentials, passwords, client secrets, refresh tokens, or exported browser sessions in chat, Git, screenshots, or documentation.

Recommended validation model:

1. Sign in locally with an administrator account:

   ```powershell
   az login --tenant contoso.onmicrosoft.com
   az account set --subscription 11111111-1111-1111-1111-111111111111
   ```

2. Run ClaudIA checks and scripts from the authenticated workstation.
3. Store generated secrets in Azure Key Vault or Automation encrypted variables.
4. Keep `.env`, `BrowserAgents/.auth`, logs, and generated output outside Git.

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

Run:

```powershell
az account show --query "{tenant:tenantId, subscription:id, name:name}" -o table
.\prerequisites\Test-Prerequisites.ps1 -RegisterProviders
```

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
.\Install-AutonomousAgents.ps1 -DryRun
```

Then run the full installer when the dry run looks correct:

```powershell
.\Install-AutonomousAgents.ps1
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
.\Install-AutonomousAgents.ps1 -DryRun
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

