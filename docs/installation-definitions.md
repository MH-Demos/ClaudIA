# Installation Definitions

`config\Installation_definitions.json` is the effective source of truth after the first installer run.

`config\agents.json` remains the editable base template for personas, schedules, and defaults. When a per-tenant config exists (`config\tenants\<key>.json`, selected via `$env:CLAUDIA_TENANT`, the az login domain, or `-ConfigPath`), it REPLACES `agents.json` as the base. Operational scripts load the resolved config first and then overlay `Installation_definitions.json` so values that change per deployment are not accidentally taken from stale template defaults.

## Per-Tenant State Pairing

The live state file is paired to the resolved tenant at installer startup
(`Sync-AAInstallationDefinitionsWithTenant` in `modules\Common.Config.ps1`):

- archives live at `config\tenants\<key>.definitions.json` and are refreshed on every save;
- switching tenants archives the previous tenant's state and restores the new one;
- a write guard THROWS if a template config (blank domain) or another tenant's config
  would overwrite real state -- set `$env:CLAUDIA_TENANT` before ANY installer run,
  including `-DryRun`;
- unowned or pre-`-Fresh` states are preserved under `config\backups\` before replacement.

## Deployment-Specific Values

Keep these values in `Installation_definitions.json`:

- `tenant.domain`
- `tenant.tenantId`
- `tenant.subscriptionId`
- `tenant.location`
- `tenant.country`
- `infrastructure.resourceGroup`
- `infrastructure.automationAccountName`
- `infrastructure.openAiAccountName`
- `infrastructure.openAiModel`
- `infrastructure.openAiModelVersion`
- `infrastructure.openAiTpm`
- `infrastructure.keyVaultName`
- `infrastructure.fabricEnabled`
- `adx.enabled`
- `adx.tenantId`
- `adx.clientId`
- `adx.clientSecretName`
- `adx.keyVaultName`
- `adx.resourceGroup`
- `adx.location`
- `adx.clusterName`
- `adx.ingestBaseUri`
- `adx.queryBaseUri`
- `adx.databaseName`
- `adx.tableName`
- `adx.mappingName`
- `adx.ingestorPrincipalId`
- `agents`

For ADX streaming ingestion, both `adx.ingestBaseUri` and `adx.queryBaseUri` should use the cluster URI without the `ingest-` prefix, for example:

```text
https://adx-claudia-lab.westus.kusto.windows.net
```

## Script Loading Rule

Scripts should use `Get-AAEffectiveConfig` from `modules\Common.ps1` when they need installation values:

```powershell
. .\modules\Common.ps1
$effective = Get-AAEffectiveConfig `
  -ConfigPath .\config\agents.json `
  -InstallationDefinitionsPath .\config\Installation_definitions.json
$config = $effective.Config
```

This prevents stale values from remaining in `agents.json` or in one-off scripts after a clean install, subscription change, ADX redeploy, or expansion pack update.
