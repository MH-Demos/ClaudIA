# Redeploying ClaudIA on a fresh subscription or tenant

When you reinstall ClaudIA on a **different subscription** or a **different
tenant**, several resources have **DNS-globally-unique** names that will collide
with the values persisted from your previous deployment in
[`config/agents.json`](../config/agents.json) and
[`config/Installation_definitions.json`](../config/Installation_definitions.json).

If you skip this preparation step, `Install-ClaudIA.ps1` will fail mid-run on
Step 4 or Step 8, leaving partial billable resources behind (Azure OpenAI,
Automation Account, Storage) that you have to clean up manually before you can
retry.

This guide explains what is at risk, and how to use the two helper scripts
that ship with ClaudIA to avoid the trap.

## Which resources are globally unique?

| Field in `agents.json` | Azure namespace | Why it matters |
|---|---|---|
| `infrastructure.openAiAccountName` | `*.openai.azure.com` | Custom subdomain, worldwide |
| `infrastructure.keyVaultName` | `*.vault.azure.net` | Worldwide, + 90-day soft-delete |
| `adx.clusterName` | `*.<region>.kusto.windows.net` | Per region, worldwide within region |
| `activityStoryMap.storageAccountName` | `*.blob.core.windows.net` | Worldwide |
| `activityStoryMap.functionStorageAccountName` | `*.blob.core.windows.net` | Worldwide |
| `activityStoryMap.functionAppName` | `*.azurewebsites.net` | Worldwide |

Fields that are **not** at risk (they are scoped to the resource group or
subscription) and need no reset:

- `infrastructure.resourceGroup`
- `infrastructure.automationAccountName`
- `infrastructure.openAiModel`, `openAiTpm`, `fabricEnabled`
- `adx.databaseName`, `tableName`, `mappingName`

## What happens if you do nothing

On a fresh subscription where the persisted names are still owned by your
previous tenant or by another customer, the installer behaviour is:

| Step | Resource | Outcome |
|---|---|---|
| Step 4 | Azure OpenAI | `DnsSubdomainExists` -> Step 4 aborts. Installer prints "globally unique, update the name and rerun". |
| Step 4 | Key Vault | `ConflictError` if soft-deleted within 90 days, or silent OK if the name has never been claimed. |
| Step 4 | Automation Account | Creates successfully (RG-scoped). **This now costs money even though the rest of Step 4 failed.** |
| Step 7 | ADX cluster | Reuses the persisted name; `az kusto cluster create` fails with `NameNotAvailable` if claimed elsewhere, otherwise OK. |
| Step 8 | Storage accounts | `StorageAccountAlreadyTaken` -> Step 8 aborts. |
| Step 8 | Function App | `WebsiteNameAlreadyExists` -> Step 8 aborts. |

In the worst case you end up editing the JSON two or three times, with
half-deployed Azure resources accumulating between each retry.

## Native wizard integration (recommended path)

Since `Install-ClaudIA.ps1` v1.1.0 the wizard runs both helpers automatically.
You do not need to call them by hand for a normal cross-tenant redeploy.

What the wizard does:

1. **Step 0 (interactive setup), after you pick a subscription.** If the
   selected subscription is different from the one persisted in
   `agents.json`, the wizard prints a yellow `[INFO]` line and invokes
   `tools\Reset-UniqueNames.ps1 -Force` for you. The 16 globally-unique-name
   fields are cleared and backed up under `config\backups\`. The OpenAI and
   Key Vault names are then regenerated from a fresh subscription-seeded
   SHA-256 hash later in the same step.

2. **Step 4 entry, before any Azure resource is created.** The wizard runs
   `tools\Test-NameAvailability.ps1` against the finalized config. If any
   name collision is detected (exit code 1), the wizard prints a red
   `[BLOCKED]` block with the offending names and the remediation command,
   and aborts **before** creating the Resource Group, Automation Account,
   Azure OpenAI, Key Vault, etc. Soft warnings (exit code 2, typically
   "not signed in to `az`") are surfaced but the wizard continues.

The standalone scripts described below remain useful for advanced cases
(running the check outside the wizard, scripted redeploys, troubleshooting,
or a manual reset between two wizard runs).

## Helper scripts

ClaudIA ships two read-only / idempotent helpers in [`tools/`](../tools/):

- [`tools/Reset-UniqueNames.ps1`](../tools/Reset-UniqueNames.ps1)
- [`tools/Test-NameAvailability.ps1`](../tools/Test-NameAvailability.ps1)

### 1. `Reset-UniqueNames.ps1`

Backs up `agents.json` and `Installation_definitions.json` into
`config/backups/` (timestamped), then clears the globally-unique fields so the
installer regenerates **fresh, deterministic, subscription-seeded** names on
the next run.

Deterministic means: as long as you keep the same `subscriptionId` and the
same `resourceGroup`, the same SHA-256-derived suffix is produced every time,
so reruns of the installer are idempotent.

By default the script only acts if it detects that the active `az` subscription
differs from the one configured in `agents.json`. Use `-Force` if you have
manually wiped the previous subscription and want to reset anyway.

#### Usage

```powershell
# Preview what would change (no files written)
.\tools\Reset-UniqueNames.ps1 -WhatIf

# Apply when the active subscription mismatches the configured one
.\tools\Reset-UniqueNames.ps1

# Apply even when the configured and active subscriptions match
.\tools\Reset-UniqueNames.ps1 -Force
```

#### What gets cleared

| Section | Fields |
|---|---|
| `infrastructure` | `openAiAccountName`, `keyVaultName` |
| `adx` | `keyVaultName`, `clusterName`, `ingestBaseUri`, `queryBaseUri` |
| `activityStoryMap` | `storageAccountName`, `functionStorageAccountName`, `functionAppName`, `staticWebsiteUrl`, `apiBaseUrl`, `launchUrl`, `source.clusterName` |
| `browserAgents` | `workspaceId`, `dataplaneUri`, `playwrightServiceUrl` |

Tenant, resource group, location, model name, schedules, agents list,
and all secret names are preserved.

### 2. `Test-NameAvailability.ps1`

Reproduces the same naming logic the installer uses, then runs a
**read-only worldwide availability check** for each candidate name **before**
you start the real deployment.

Checks performed:

- **Azure OpenAI** : DNS resolution of `<name>.openai.azure.com`.
- **Key Vault** : DNS resolution of `<name>.vault.azure.net` plus
  `az keyvault list-deleted` to surface soft-deleted vaults blocking the name.
- **Storage accounts** (site + function) : ARM
  `Microsoft.Storage/checkNameAvailability` API.
- **Function App** : DNS resolution of `<name>.azurewebsites.net`.
- **ADX cluster** : DNS resolution of `<name>.<region>.kusto.windows.net`
  (only if a cluster name is already pinned in `agents.json`).

Exit codes:

- `0` All future names are globally available.
- `1` At least one collision was detected (see the `[FAIL]` block in the output).
- `2` At least one check could not complete (typically: not signed into `az`).

#### Usage

```powershell
# Plain check
.\tools\Test-NameAvailability.ps1

# Verbose, shows the seed material used for the SHA-256 suffixes
.\tools\Test-NameAvailability.ps1 -Detailed
```

## Recommended workflow on a fresh tenant

```powershell
# 1. Switch az to the new subscription
az login --tenant <new-tenant-id>
az account set --subscription <new-subscription-id>

# 2. Preview the reset
.\tools\Reset-UniqueNames.ps1 -WhatIf

# 3. Apply the reset (a timestamped backup is written under config\backups\)
.\tools\Reset-UniqueNames.ps1

# 4. Update tenant.subscriptionId and tenant.tenantId in agents.json
#    (this script does NOT change those - you change tenants intentionally)

# 5. Pre-flight check the names the installer is about to generate
.\tools\Test-NameAvailability.ps1

# 6. Once Test-NameAvailability returns 0, run the wizard or the installer
.\Install-ClaudIA.ps1
```

If `Test-NameAvailability.ps1` returns `1`, edit the offending field in
`agents.json` to a custom value (for example append your initials), then rerun
the check until you get exit code `0`.

## Restoring a previous configuration

Every reset writes a timestamped copy under `config/backups/`:

```
config/backups/agents.20260611-184205.bak.json
config/backups/Installation_definitions.20260611-184205.bak.json
```

To roll back, copy the backup back over the live file:

```powershell
Copy-Item .\config\backups\agents.20260611-184205.bak.json .\config\agents.json -Force
Copy-Item .\config\backups\Installation_definitions.20260611-184205.bak.json .\config\Installation_definitions.json -Force
```

## Related documentation

- [`installation-definitions.md`](installation-definitions.md) explains how
  `Installation_definitions.json` is merged on top of `agents.json` at install
  time.
- [`troubleshooting.md`](troubleshooting.md) covers the runtime errors you may
  hit if you skip the pre-flight (Key Vault Forbidden, OpenAI conflict, etc.).
