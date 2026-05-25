# Devon Reyes Expansion Pack

This pack adds a controlled data-leakage and shadow-AI scenario centered on Devon Reyes.

## What It Adds

- Devon Reyes now uses the `ExternalAI` workload and remains without a Microsoft Copilot license.
- Sofia Lopez and Miguel Santos also use `ExternalAI` so the scenario is not isolated to one user.
- Four Teams-backed SharePoint collaboration sites are defined in `config/agents.json`:
  - `CorpLab - Executive AI Risk`
  - `CorpLab - Commercial Finance AI`
  - `CorpLab - Operations Legal AI`
  - `CorpLab - Security Shadow AI`
- Simulated non-Copilot AI services:
  - Azure AI Foundry - Grok
  - Azure AI Foundry - Llama
  - Azure AI Foundry - DeepSeek
  - Azure AI Foundry - Claude

## Runtime Behavior

The existing `Invoke-AgentRunbook` remains the orchestrator. A separate runbook is not required for this first pack.

Agents with `workload: ExternalAI` generate controlled non-Copilot AI interactions. The runbook:

- Generates a sensitive AI prompt and response through the existing Azure OpenAI deployment.
- Logs the activity to ADX with `ActivityType == "external_ai"`.
- Uploads a Markdown evidence artifact into the agent's collaboration SharePoint site.
- Posts a short activity note in the matching collaboration Team when channel posting is available.

## Real Foundry Pilot

`config/agents.json` includes `externalAiRuntime` for a one-agent real-model pilot:

```json
"externalAiRuntime": {
  "enabled": true,
  "mode": "foundry",
  "agentSams": ["devon.reyes"],
  "serviceName": "Azure AI Foundry - DeepSeek",
  "endpoint": "",
  "deploymentName": "DeepSeek-V3.1",
  "authMode": "ManagedIdentity",
  "fallbackToSimulation": true
}
```

To activate the real call, deploy a chat model in Azure AI Foundry and set:

- `endpoint`: Foundry/Azure OpenAI compatible endpoint, for example `https://<resource>.openai.azure.com/openai/v1`.
- `deploymentName`: the deployment name in Foundry, for example `DeepSeek-V3.1`.
- `agentSams`: keep only `devon.reyes` for the initial pilot.

The runbook uses managed identity bearer authentication for Foundry. Grant the Automation Account managed identity access to the Foundry resource before running the pilot. If the Foundry call fails and `fallbackToSimulation` is `true`, the runbook still records the event as `FoundryFallbackSimulation` instead of stopping the job.

Important: a real Foundry call produces real Azure model invocation and ADX telemetry from this lab, but it does not automatically guarantee a native Purview DSPM for AI `AI Interaction` record unless the model/app path is covered by Purview capture policies or an app integration supported by Purview.

## Deployment

```powershell
.\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites
.\Install-ClaudIA.ps1 -Step 5 -SkipPrerequisites
```

Step 4 provisions the additional Teams/SharePoint sites and stores `AgentCollaborationSites`.
Step 5 republishes the runbook and stores the updated agent and thread configuration.

## ADX Validation Query

```kusto
CLAUDIA_Activity
| where Event.ActivityType == "external_ai"
| project TimeGenerated, AgentName=tostring(Event.AgentName), Department=tostring(Event.Department), Service=tostring(Event.Service), RuntimeMode=tostring(Event.RuntimeMode), FoundryDeployment=tostring(Event.FoundryDeployment), Detail=tostring(Event.Detail), Prompt=tostring(Event.PromptContent), Response=tostring(Event.ResponseContent)
| order by TimeGenerated desc
```

SharePoint and Teams content should also be visible to Purview DLP/DSPM once crawled and indexed.

## Service Logos

The Activity Story Map resolves short service keys for external AI services. You can place any of these files in `Images\Services` and then run `.\tools\Publish-ActivityStoryMapAssets.ps1`:

- `DeepSeek.png`
- `Claude.png`
- `Grok.png`
- `Llama.png`
- `Azure AI Foundry.png`
