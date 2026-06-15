# MCAPS / Hardened Tenant Daily Reachability

This page documents what to do when ClaudIA is deployed in a Microsoft Managed
Environment subscription (MCAPS), a Microsoft hardened test tenant, or any
other Azure subscription that re-applies "Deny public network access" Azure
Policy on a daily schedule.

If you are deploying ClaudIA into a Visual Studio Enterprise, Pay-As-You-Go,
sponsored, or normal customer subscription you can skip this page. The
wizard's only-on-deploy reachability fix is enough for those subscriptions.

## Symptom

At the end of `Step 4 - Deploy core Azure infrastructure` you see this banner
(yellow text):

```
  ==================== HARDENED TENANT DETECTED ====================
  This wizard had to re-enable publicNetworkAccess on:
    - Key Vault              kvclaudialab
    - Azure OpenAI           oai-claudia-lab
    - Automation             aa-claudia-lab

  This pattern matches MCAPS / Microsoft Managed Environment / hardened test tenants
  that re-apply 'Deny public network access' Azure Policy on a daily schedule.
  ...
```

The banner only fires when the wizard had to flip `publicNetworkAccess` back
to `Enabled` on at least one resource. If you see it, the host subscription
is on a daily hardening schedule and the lab will silently degrade overnight
unless you put automation in place.

## Why it happens

MCAPS, Microsoft Managed Environment and most internal "hardened" test
tenants enforce an Azure Policy assignment that, on a daily schedule, flips
`properties.publicNetworkAccess` back to `Disabled` on:

- Key Vault (`Microsoft.KeyVault/vaults`)
- Cognitive Services / Azure OpenAI (`Microsoft.CognitiveServices/accounts`)
- Automation Account (`Microsoft.Automation/automationAccounts`)
- Azure Data Explorer cluster (`Microsoft.Kusto/clusters`)
- Storage Account (`Microsoft.Storage/storageAccounts`)

The same tenants typically auto-stop ADX Dev / Basic SKU clusters after about
five days of inactivity, on top of the policy.

## What breaks without daily automation

| Component | Failure |
| --- | --- |
| Wizard rerun of Step 5 | `Key Vault secret 'agent-client-secret' was not stored` because `az keyvault secret set` returns `(Forbidden) ... ForbiddenByConnection`. |
| Autonomous agent runbook (`Invoke-AgentRunbook.ps1`) | Cannot read `agent-client-secret` from Key Vault (the cloud sandbox has no stable egress IP and is not in the Key Vault trusted-services bypass list). The runbook silently fails on every scheduled invocation. |
| ADX ingestion + queries | `kusto.windows.net` ingestion endpoint returns network deny; the Activity Story Map and workbook return empty data. |
| ADX Dev/Basic SKU cluster | Auto-stopped after about five days; ingestion + queries fail with `clusterIsStopped`. |
| Azure OpenAI generation | Control-plane writes from the operator workstation hit network-deny on rerun. Existing runbook calls via managed identity over the public endpoint also fail when PNA is Disabled. |
| Browser-agent local runs | Cannot read secrets from Key Vault. |

## Why ClaudIA does not lock Key Vault to your workstation IP

The first thing you might consider is "just let me allowlist my workstation
IP on Key Vault, then PNA can stay Disabled". We deliberately do not do this
and we recommend you do not either, for one reason:

`modules\Invoke-AgentRunbook.ps1` runs inside the Azure Automation cloud
sandbox. The cloud sandbox has no stable egress IP, and Azure Automation is
NOT in the Key Vault `bypass=AzureServices` trusted-services list (which
covers SharePoint, Exchange, Cosmos DB, Purview, Synapse and ACR, but not
Automation).

If you lock Key Vault to your workstation IP, the operator wizard runs
succeed but every scheduled agent runbook execution fails to read its client
secret, silently. The lab looks healthy in the portal and is completely
broken end-to-end.

Recommendation: keep `publicNetworkAccess=Enabled` on Key Vault, rely on
Entra ID + RBAC (the wizard already configures Key Vault with
`--enable-rbac-authorization true`), and re-enable PNA on a schedule using
the runbook below.

## Fix: schedule the reachability runbook

ClaudIA ships a turnkey runbook that re-applies the wizard's reachability
state daily. Run it once from your workstation after Step 4 has succeeded:

```powershell
cd ClaudIA
.\tools\Deploy-LabReachabilityRunbook.ps1 -ResourceGroup rg-claudia-lab
```

The deployer does four things:

1. Reads `Installation_definitions.json` to discover the Automation Account,
   Key Vault, Azure OpenAI account and ADX cluster names.
2. Grants the Automation Account's system-assigned managed identity the
   `Contributor` role on the resource group (so the runbook can PATCH PNA
   and call `/start` on the cluster).
3. Uploads `tools\Restore-LabPublicNetworkAccess.ps1` as a PowerShell 7.2
   runbook named `Restore-LabPublicNetworkAccess`.
4. Creates a daily 06:00 UTC schedule named `Daily-Reachability-Restore` and
   links it to the runbook with `-ResourceGroup <rg>` and
   `-UseAutomationManagedIdentity:$true`.

After deployment, the runbook idempotently:

- PATCHes `publicNetworkAccess=Enabled` on Key Vault, Azure OpenAI,
  Automation Account and the ADX cluster (only if currently not Enabled).
- Issues `/start` on the ADX cluster if its state is `Stopped`.
- Skips silently when nothing needs changing.

You can also run the script ad-hoc from your workstation without scheduling:

```powershell
cd ClaudIA
.\tools\Restore-LabPublicNetworkAccess.ps1 -ResourceGroup rg-claudia-lab
```

The wizard does not auto-deploy the runbook. The choice to grant the
Automation MI `Contributor` on the resource group is yours, not ours.

## Alternatives

If you prefer not to grant the Automation MI `Contributor` on the resource
group, any of these work:

- Run `Restore-LabPublicNetworkAccess.ps1` from a separate Logic App with a
  workload-identity service principal scoped to the same resource group.
- Run it from a GitHub Action with a federated credential on the same SP.
- Move the lab to a non-hardened subscription (Visual Studio Enterprise,
  Pay-As-You-Go, sponsored).

All three call exactly the same PATCH + `/start` operations as the runbook.

## Storage: `allowSharedKeyAccess=false` is forced at write time

Unlike `publicNetworkAccess` (flipped back nightly, so the wizard can re-enable
it), some hardened tenants run a **Modify-effect Azure Policy that rewrites
`allowSharedKeyAccess=false` during the create/update call itself**. A PATCH
sending `true` returns `false` in the response body. It cannot be overridden,
not even temporarily.

Consequences:

- Account keys and key-based SAS are unusable (`az storage account keys list`
  returns keys, but every data-plane call with them gets 403).
- The classic **Windows Consumption** Function plan cannot be created - it
  needs a key-based file share and fails with
  `Creation of storage file share failed with: '(403) Forbidden'`.

**The wizard handles this automatically** (Step 8, Activity Story Map):
after creating the storage account it reads back `allowSharedKeyAccess`.
If the policy forced it to `false`, the deployment switches to:

- **Flex Consumption** plan with `--deployment-storage-auth-type
  SystemAssignedIdentity` (no keys anywhere), and
- **Entra ID blob auth** (`--auth-mode login`) for the static website upload,
  granting the signed-in user `Storage Blob Data Contributor` and retrying
  while RBAC propagates.

The wizard also pre-checks plan availability before creating anything:
Consumption (Dynamic SKU) quota via `Microsoft.Web/geoRegions?sku=Dynamic`,
and Flex regional support via `az functionapp list-flexconsumption-locations`.
If the region supports neither, it stops with a clear message instead of
failing mid-deploy. On non-hardened tenants nothing changes - the default
Windows Consumption path is used.

## Also worth knowing about hardened tenants

These items are NOT handled by the wizard or the runbook and may require
separate action depending on the lab features you enable:

- **VM auto-deallocation at off-hours.** No impact on the core ClaudIA lab
  today, but matters if you add Hybrid Runbook Workers, self-hosted
  Integration Runtimes or ADX VNet injection.
- **Conditional Access blocking ROPC.** If you enable BrowserAgent persona
  logins, exclude `grp-claudia-agent-mfa-exclusion` from MFA and "Block
  legacy authentication" policies.
- **`disableLocalAuth=true` on Cognitive Services.** ClaudIA already uses
  managed identity for Azure OpenAI, so this is fine. For Storage, see the
  dedicated `allowSharedKeyAccess` section above - the wizard auto-detects
  and falls back to Entra-only auth.
- **Key Vault soft-delete purge cycle.** Soft-deleted secrets get purged on
  a 7-30 day cycle in hardened tenants. Do not rely on "Recover deleted
  secret" for production secrets.

## Related files

- `tools/Restore-LabPublicNetworkAccess.ps1` - the idempotent reachability
  script (runs locally or as a runbook).
- `tools/Deploy-LabReachabilityRunbook.ps1` - one-shot deployer that uploads
  the runbook and schedules it daily.
- `modules/Common.ps1` - `Ensure-AAResourcePublicNetworkEnabled` +
  `Write-AAHardeningTenantWarning` (the wizard-side detection + banner).
- `modules/Deploy-AzureInfra.ps1` - Step 4 call sites for Key Vault, Azure
  OpenAI and Automation Account.
- `tools/Deploy-AdxTelemetry.ps1` - the ADX-side equivalent
  (`Enable-AdxClusterPublicNetworkAccess` + `Write-AdxHardeningTenantWarning`).
- `modules/Deploy-ActivityStoryMap.ps1` - Step 8 shared-key detection, plan
  quota preflight and Flex Consumption + managed identity fallback.
