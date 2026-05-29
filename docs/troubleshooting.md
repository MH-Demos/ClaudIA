# Troubleshooting

This guide covers common ClaudIA setup, deployment, and runtime issues.

ClaudIA is designed for lab, demo, training, and testing environments. Do not use these steps against production tenants or production data.

## First Checks

Before troubleshooting a specific error, confirm the basics:

```powershell
az logout
az login --tenant contoso.onmicrosoft.com
az account set --subscription 11111111-1111-1111-1111-111111111111

.\prerequisites\Test-Prerequisites.ps1
.\tools\Test-PublicRepoSafety.ps1
```

Confirm that:

- You are in the ClaudIA repository root.
- You cloned or downloaded the full repository, not only `Install-ClaudIA.ps1`.
- You are using a lab tenant.
- The Azure subscription is visible to the signed-in account.
- The deploying account has the required Entra, Microsoft 365, and Azure permissions.
- Runtime secrets are stored in Azure Key Vault.
- Browser session files and `.env` files are not committed.

## PowerShell And Repository Issues

### PowerShell says the script is not digitally signed

**Symptom**

```text
File ...\Install-ClaudIA.ps1 cannot be loaded. The file is not digitally signed.
```

**Cause**

Windows marked downloaded `.ps1` files with the internet zone.

**Fix**

Run from the ClaudIA repository root:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
.\Install-ClaudIA.ps1
```

If your organization enforces `AllSigned`, use a lab workstation where local scripts are allowed or ask your administrator to approve a temporary lab execution policy.

### The installer cannot find `modules\Common.ps1`

**Cause**

Only part of the repository was downloaded.

**Fix**

Clone or download the complete repository, then run the installer from the root folder that contains `modules`, `config`, `tools`, `prerequisites`, and `Install-ClaudIA.ps1`.

```powershell
git clone https://github.com/MH-Demos/ClaudIA.git C:\MyDev\ClaudIA
cd C:\MyDev\ClaudIA
Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
.\Install-ClaudIA.ps1
```

## Azure And Tenant Access Issues

### Azure CLI says the selected account does not exist in the tenant

**Cause**

The Azure account selected during sign-in is not a user in the target Entra tenant. This is common when the Azure subscription owner belongs to another organization.

**Fix**

1. Invite the account as an external user in the target Entra tenant.
2. Have the user accept the invitation.
3. Assign Owner or Contributor on the target subscription or ClaudIA resource group.
4. Run the installer again and sign in to the target tenant.

When possible, use a native target-tenant administrator for first-time setup.

### Azure CLI login succeeds but no subscriptions are visible

**Cause**

The account exists in the tenant but does not have Azure RBAC on the target subscription.

**Fix**

Assign Owner or Contributor on the target subscription or on the ClaudIA resource group, then verify:

```powershell
az logout
az login --tenant contoso.onmicrosoft.com
az account list -o table
```

Only continue when the target subscription appears in `az account list`.

### Prerequisites fail because resource providers are not registered

**Cause**

New Azure subscriptions often have required resource providers in `NotRegistered` state.

**Fix**

Let ClaudIA register the providers:

```powershell
.\Install-ClaudIA.ps1 -RegisterProviders
```

Or register providers manually:

```powershell
az provider register -n Microsoft.CognitiveServices --wait
az provider register -n Microsoft.Automation --wait
az provider register -n Microsoft.KeyVault --wait
az provider register -n Microsoft.Kusto --wait
az provider register -n Microsoft.Web --wait
az provider register -n Microsoft.Storage --wait
```

### The deploying user has no admin directory role

**Cause**

The signed-in account can access Azure but is not a Microsoft 365 / Entra deployment administrator in the target tenant.

**Fix**

Use an account with both Azure RBAC and tenant admin rights, or grant the required setup roles in the demo tenant.

For the simplest first deployment, use a single account with:

- Owner or Contributor on the Azure subscription or resource group.
- Global Administrator or Privileged Role Administrator for initial setup.

If Azure and Microsoft 365 are managed by different people, use the installer prompt for a separate Microsoft 365 / Entra admin sign-in.

## Tenant Readiness Issues

### ROPC returns `AADSTS50126: Invalid username or password`

**Cause**

The persona password stored in Azure Key Vault does not match the actual Entra user password, or the wrong Key Vault secret name is referenced in configuration.

**Fix**

1. Confirm the persona's `keyVaultSecretName` in `config/agents.json`.
2. Confirm the secret exists in the configured Key Vault.
3. Reset the Entra user password if needed.
4. Update the Key Vault secret value.
5. Re-run the relevant deployment or runbook publication step.

Example Key Vault update:

```powershell
az keyvault secret set --vault-name kv-claudia-lab --name devon-reyes --value "<new-lab-password>"
```

Do not store the password in Git, `.env`, screenshots, or documentation.

### ROPC returns `AADSTS50079` or MFA required

**Cause**

The persona is not in the dedicated ClaudIA MFA exclusion group, or the Conditional Access policy exclusion was not saved.

**Fix**

1. Verify the user is a member of `grp-claudia-agent-mfa-exclusion`.
2. Verify the Conditional Access policy excludes only that dedicated group.
3. Confirm the agent account has no admin roles.
4. Retry the runbook or BrowserAgent flow.

Never assign admin roles to MFA-excluded persona accounts.

### Security Defaults block lab automation

**Cause**

Brand-new tenants may have Security Defaults enabled. Security Defaults is good for real tenants, but it conflicts with unattended lab automation that cannot satisfy MFA.

**Fix**

For a lab tenant only:

1. Confirm the tenant is not production.
2. Disable Security Defaults.
3. Create a dedicated ClaudIA agent MFA exclusion group.
4. Create Conditional Access policies that require MFA for normal users.
5. Exclude only the ClaudIA agent group.
6. Never assign admin roles to excluded agent accounts.

## Key Vault Issues

### Key Vault Forbidden errors

**Cause**

The runtime identity, Automation managed identity, Function App managed identity, or deployment account does not have the required Key Vault data-plane permission.

**Fix**

1. Confirm the Key Vault name in `config/agents.json`.
2. Confirm the identity that needs to read secrets.
3. Grant the appropriate Key Vault role, such as Key Vault Secrets User for runtime read access or Key Vault Secrets Officer for setup operations.
4. Retry the deployment or runbook.

Example:

```powershell
$kvId = az keyvault show -n kv-claudia-lab -g rg-claudia-lab --query id -o tsv
$principalId = az automation account show -n aa-claudia-lab -g rg-claudia-lab --query identity.principalId -o tsv
az role assignment create --role "Key Vault Secrets User" --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $kvId
```

### A secret exists but the runbook cannot find it

**Cause**

The secret name in `config/agents.json` does not match the name stored in Key Vault, or the runbook is using an outdated configuration snapshot.

**Fix**

1. Compare `keyVaultSecretName` for the persona with the Key Vault secret name.
2. Re-publish the runbook or rerun the relevant installer step.
3. Confirm Automation variables contain non-secret configuration or secret-name references, not plaintext passwords.

## Microsoft 365 Workload Issues

### Persona photo upload fails with `ForbiddenByPolicy` or `invalid_role`

**Cause**

The photo upload is using a token from an account that can access Azure but cannot update Microsoft 365 / Entra user photos.

**Fix**

Sign in with a Microsoft 365 / Entra admin account that can update user photos:

```powershell
.\tools\Set-EntraUserPhotos.ps1 -SkipMissing
```

If the installer collected a separate Microsoft 365 admin sign-in, pass that Azure CLI profile:

```powershell
.\tools\Set-EntraUserPhotos.ps1 -SkipMissing -M365AzureConfigDir .\.claudia\az-m365-admin
```

### Teams team creation fails

**Cause**

The admin account does not have the required Teams role, Teams is not provisioned, or duplicate teams already exist.

**Fix**

1. Confirm the admin account has Teams Administrator or Global Administrator role.
2. Confirm Teams is enabled in the tenant.
3. Remove duplicate demo teams if needed.
4. Re-run the relevant setup step.

### SharePoint site is not ready

**Cause**

Microsoft 365 group-backed SharePoint sites can take time to provision after team creation.

**Fix**

Wait a few minutes, then re-run the relevant setup step. Existing teams should be detected and the site URL should resolve on retry.

### Teams posts fail with 403

**Cause**

The persona token does not have the required delegated permissions, admin consent is missing, or Teams channel configuration was not created.

**Fix**

1. Verify delegated Graph consent includes Teams messaging scopes required by ClaudIA.
2. Re-run the agent app registration step if permissions are missing.
3. Re-publish runbook configuration.
4. Confirm the Teams/channel references exist.

### Connect-IPPSSession hangs or fails

**Cause**

Security & Compliance PowerShell requires interactive authentication and may open a browser prompt.

**Fix**

Pre-connect before running the wizard:

```powershell
Connect-IPPSSession
.\Install-ClaudIA.ps1 -SkipPrerequisites
```

## ADX And Telemetry Issues

### `CLAUDIA_Activity` table is empty

**Possible causes**

- ADX was deployed but no runbook or BrowserAgent activity has executed yet.
- The ingestion identity does not have ADX database ingestor permissions.
- The configuration points to the wrong cluster, database, or table.
- Weekend or schedule logic skipped execution.
- BrowserAgent ADX ingestion was disabled for local testing.

**Fix**

```powershell
.\tools\Deploy-AdxTelemetry.ps1
.\tests\Test-SingleAgent.ps1 -Agent priya.sharma
```

Then query ADX:

```kusto
CLAUDIA_Activity
| order by TimeGenerated desc
| take 50
```

### Activity Story Map loads but shows no activity

**Cause**

The portal is reachable, but the API cannot query ADX or no telemetry exists for the selected time range.

**Fix**

1. Confirm `activityStoryMap.apiBaseUrl` in `config/agents.json`.
2. Confirm the Azure Function can query ADX.
3. Confirm `CLAUDIA_Activity` contains recent rows.
4. Increase the portal lookback window.
5. Republish portal assets if configuration changed.

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

### Legacy Sentinel rules show no incidents

**Cause**

Older custom rules may reference legacy Log Analytics tables, while the current public telemetry path writes to ADX table `CLAUDIA_Activity`.

**Fix**

Use the ADX workbook, Activity Story Map, or ADX queries for the current telemetry path. Maintain legacy Sentinel rules only if you intentionally run a legacy Log Analytics / Sentinel branch.

## BrowserAgent Issues

### BrowserAgent cannot authenticate

**Cause**

The persona password, browser session, Conditional Access policy, or Key Vault secret reference may be invalid.

**Fix**

1. Confirm the persona secret in Key Vault.
2. Confirm the persona is allowed by the lab Conditional Access design.
3. Delete stale local session state under `BrowserAgents/.auth` if needed.
4. Re-run authentication:

```powershell
.\tools\Invoke-BrowserAgentAuth.ps1 -Agent priya.sharma
```

### BrowserAgent Azure run fails with Playwright permissions

**Cause**

The runner identity does not have the required role on the Playwright workspace.

**Fix**

Grant the required Playwright Workspace role and validate:

```powershell
.\tools\Test-BrowserAgentWorkspace.ps1
```

### BrowserAgent files were accidentally created locally

**Fix**

Do not commit generated BrowserAgent artifacts. Remove or ignore:

- `BrowserAgents/.auth`
- `BrowserAgents/node_modules`
- `BrowserAgents/playwright-report`
- `BrowserAgents/test-results`
- `.env`

Run:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

## Azure OpenAI And AI Foundry Issues

### Azure OpenAI returns 403

**Cause**

The runtime identity does not have permission to call the Azure OpenAI resource.

**Fix**

Grant `Cognitive Services OpenAI User` to the runtime identity on the Azure OpenAI resource.

```powershell
$aaObjId = az automation account show --name aa-claudia-lab -g rg-claudia-lab --query identity.principalId -o tsv
$oaiId = az cognitiveservices account show -n oai-claudia-lab -g rg-claudia-lab --query id -o tsv
az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $aaObjId --assignee-principal-type ServicePrincipal --scope $oaiId
```

### External AI scenario falls back to simulation

**Cause**

The configured external AI runtime is not available, the deployment name is wrong, or managed identity access is missing.

**Fix**

1. Check `externalAiRuntime` in `config/agents.json`.
2. Confirm the endpoint, deployment, and auth mode.
3. Confirm managed identity access.
4. Keep `fallbackToSimulation` enabled when you want the demo to continue even if the external runtime is unavailable.

## Fabric And OneLake Issues

### OneLake upload fails with 403

**Possible causes**

- Missing `storage.azure.com/user_impersonation` scope on the Entra app.
- Admin consent was not granted for the storage scope.
- Fabric capacity is paused.
- Workspace or Lakehouse IDs are wrong.

**Fix**

1. Confirm the app registration permissions and admin consent.
2. Confirm Fabric capacity is running.
3. Confirm workspace and Lakehouse IDs.
4. Re-run the relevant Fabric setup step.

### Fabric capacity creation fails

**Cause**

The selected Fabric capacity SKU may not be available in the selected region.

**Fix**

Change the configured location to a supported region or use an existing Fabric workspace / Lakehouse when the installer supports that path.

## Logs And Diagnostics

| Source | How to access | What it shows |
| --- | --- | --- |
| Automation job output | Azure Portal > Automation > Jobs > Output | Agent activity and runtime messages. |
| Automation job streams | Azure Portal > Automation > Jobs > Errors/Warnings | Authentication failures, API errors, script warnings. |
| `CLAUDIA_Activity` | Azure Data Explorer > configured database > `CLAUDIA_Activity` | Normalized agent activity telemetry. |
| Activity Story Map API | Azure Function App | Portal graph data backed by ADX. |
| Activity Explorer | Microsoft Purview portal | Audit, DLP, label, and workload activity where available. |
| BrowserAgent reports | Local Playwright folders | Local browser automation troubleshooting only; do not commit. |

## When To Re-Run The Installer

The installer is designed to be re-run for repair or completion. Use dry run mode before applying changes:

```powershell
.\Install-ClaudIA.ps1 -DryRun
```

If you know the affected area, use the relevant step or tool instead of rebuilding everything.

## Public-Safety Reminder

Before sharing logs, screenshots, issues, or documentation updates, remove:

- Tenant IDs.
- Subscription IDs.
- App IDs.
- UPNs from real tenants.
- Secrets.
- Tokens.
- Connection strings.
- Browser sessions.
- Production data.

Then run:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```
