# Tools

This folder contains operational scripts used to validate, run, publish, update, troubleshoot, and maintain ClaudIA.

If `Install-ClaudIA.ps1` is the main deployment entry point, the `tools` folder is the operator toolkit.

## What This Folder Is For

Use this folder when you need to:

- Validate whether the repository is safe to publish.
- Update ClaudIA scripts without overwriting local tenant configuration.
- Back up or restore local configuration.
- Publish Activity Story Map assets.
- Upload persona photos.
- Run BrowserAgent tasks.
- Manage external recipients.
- Enable or disable Copilot-specific tasks.
- Publish or refresh runbooks.
- Validate ADX, MDCA, browser automation, or portal-related components.
- Manage lab cost and operational status.

## Common Tools

| Script | Purpose |
| --- | --- |
| `Test-PublicRepoSafety.ps1` | Scans the repository for secrets, generated artifacts, and files that should not be published. |
| `Update-ClaudIAScripts.ps1` | Updates PowerShell scripts from the version manifest without replacing tenant configuration. |
| `Backup-ClaudIAConfiguration.ps1` | Backs up or restores local configuration files before replacing repository content. |
| `Publish-ActivityStoryMapAssets.ps1` | Publishes images, branding, personas, and static assets for the Activity Story Map. |
| `Set-EntraUserPhotos.ps1` | Uploads persona photos to Microsoft Entra ID users. |
| `Invoke-BrowserAgentAuth.ps1` | Creates or refreshes browser authentication state for a persona. |
| `Invoke-BrowserAgentDaily.ps1` | Runs browser-based persona activity for selected services. |
| `Invoke-BrowserAgentSmoke.ps1` | Runs a browser-agent smoke test locally or with Azure-hosted browsers. |
| `Manage-ExternalRecipients.ps1` | Lists, adds, or removes lab-approved external recipients. |
| `Set-CopilotTasks.ps1` | Enables or disables Copilot-specific scheduled tasks. |
| `Publish-RunbookOnly.ps1` | Publishes runbook changes without running the complete installer. |

The exact script set may evolve. Review script help or source comments before running a tool in a new tenant.

## First Commands To Know

Check whether the repository is safe to publish:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

Back up configuration before replacing repository files:

```powershell
.\tools\Backup-ClaudIAConfiguration.ps1
```

Restore the latest configuration backup:

```powershell
.\tools\Backup-ClaudIAConfiguration.ps1 -Mode Restore
```

Update only ClaudIA scripts:

```powershell
.\tools\Update-ClaudIAScripts.ps1
```

Publish Activity Story Map assets:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

## Safety Rules

Before running tools:

1. Confirm you are in the correct repository root.
2. Confirm you are signed in to the intended tenant and subscription.
3. Confirm this is a lab tenant, not production.
4. Review any script that changes users, policies, runbooks, secrets, or Azure resources.
5. Keep secrets in Azure Key Vault.
6. Do not commit generated output.

## Azure Sign-In Reminder

Many tools expect Azure CLI or Microsoft Graph context to already exist.

Use a clean sign-in when switching tenants:

```powershell
az logout
az login --tenant contoso.onmicrosoft.com
az account set --subscription 11111111-1111-1111-1111-111111111111
```

If Azure and Microsoft 365 administration are separated, follow the installer guidance for using a separate Microsoft 365 / Entra admin sign-in.

## Generated Files

Do not commit generated outputs from tool runs.

Common examples:

- Logs.
- Temporary JSON files.
- Browser session files.
- Playwright reports.
- Exported validation output.
- Local backups.
- `.env` files.

Run the public-safety check before sharing or publishing changes.
