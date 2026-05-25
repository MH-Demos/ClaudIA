# Operational Considerations

## Safety Boundaries

This lab is not intended for production. It uses ROPC, creates or uses existing users, generates synthetic content with fictitious PII, applies labels, triggers DLP/IRM scenarios, and creates real Microsoft 365 activity.

Before operating the lab:

- Confirm that the tenant is a lab or demo tenant.
- Confirm that agent accounts can be excluded from MFA.
- Confirm that the `grp-claudia-agent-mfa-exclusion` group is covered by Conditional Access policy.
- Confirm that no sensitive real user will be used as an agent.
- Confirm that the Azure resource costs are accepted.

## Idempotency

Most steps attempt to be idempotent, but not every change is reversible:

- Creating users, groups, teams, labels, and policies can leave tenant objects behind.
- ADX, Storage, Function Apps, and Automation resources are persistent Azure resources.
- Schedules remain active until disabled.
- DLP/IRM changes can take time to activate or become visible.

Rerunning is normal, but the recommended pattern is:

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step <n> -SkipPrerequisites
```

## Known Timing Issues

- Entra ID can take time to resolve newly created users.
- License assignment can take time to enable workloads.
- Purview labels and DLP policies can take time to propagate.
- ADX cluster/database provisioning can take several minutes.
- ADX streaming ingestion is near-real-time, but not always immediate.
- Azure Automation runbook content can be stale if the draft was not published correctly.

## Recommended Smoke Tests

After Step `4`:

```powershell
.\tests\Test-AzureOpenAI.ps1
.\tools\Test-InstallationDefinitionsConsistency.ps1
```

After Step `5`:

```powershell
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
```

After ADX, workbook, and Story Map deployment:

```powershell
.\tests\Test-FullRun.ps1 -Agents ana.rodriguez,carlos.delgado -ADXWaitMinutes 2
.\tools\Invoke-ActivityStoryMapRefresh.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

## Troubleshooting Paths

Authentication failure:

```powershell
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez
.\tools\Reset-AgentPasswords.ps1 -Agent ana.rodriguez
```

Stale runbook:

```powershell
.\tools\Publish-RunbookOnly.ps1
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
```

Empty ADX results:

```powershell
.\tools\Test-InstallationDefinitionsConsistency.ps1
.\tests\Test-FullRun.ps1 -Agents ana.rodriguez -ADXWaitMinutes 5
```

Missing Story Map images:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

Missing Story Map activity:

```powershell
.\tools\Invoke-ActivityStoryMapRefresh.ps1 -Parallel -ThrottleLimit 5 -ADXWaitMinutes 2
```

DLP/IRM script failures:

```powershell
Import-Module ExchangeOnlineManagement
Connect-IPPSSession
.\Install-ClaudIA.ps1 -UseInstallationDefinitions -Step 6 -SkipPrerequisites
```

## Cost Management

Primary cost levers:

- Number of agents.
- Number of schedules.
- Azure OpenAI model and TPM.
- ADX cluster SKU.
- Fabric capacity, if enabled.

Commands:

```powershell
.\Manage-Costs.ps1 -Action Status
.\Manage-Costs.ps1 -Action Estimate
.\Manage-Costs.ps1 -Action ReduceSchedule
.\Manage-Costs.ps1 -Action FullSchedule
```

## Data and Demo Quality

To keep the demo story coherent:

- Keep `Storyline/profiles.md` aligned with `config/agents.json`.
- Keep `config/email-threads.json` aligned with the active personas.
- Use `Add-StorylineAgents.ps1` to expand the cast without replacing the original one.
- Publish images with `Publish-ActivityStoryMapAssets.ps1`.
- Run `Test-FullRun.ps1` before opening the Story Map.

## Cleanup Considerations

There is no complete cleanup script documented for removing everything. If cleanup is required:

- Disable schedules first.
- Export or back up `Installation_definitions.json`.
- Remove Azure resources by resource group only if the group does not contain shared resources.
- Review DLP, IRM, and labels before deleting them manually.
- Remove users/agents only if they were created exclusively for the lab.

