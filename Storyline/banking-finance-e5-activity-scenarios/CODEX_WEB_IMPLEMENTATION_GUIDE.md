# Codex Web Implementation Guide

## Intent

Use this guide when converting the banking/finance scenario pack into executable browser or Graph-backed activity. The companion file `web-implementation-feasibility-review.md` is the planning source of truth for short, medium, and long horizon classification.

## Current Repo Baseline

Codex should assume these local capabilities already exist:

- Persona users and Devon Reyes in `ClaudIA/config/agents.json`.
- Stored BrowserAgent auth states in `ClaudIA/BrowserAgents/.auth`.
- Playwright tests for OWA, Office Web, Copilot Web, Internal AI Workbench and preflight checks in `ClaudIA/BrowserAgents/tests`.
- Graph/runbook support for SharePoint, Teams, Exchange, labels, external AI logging and ADX telemetry in `ClaudIA/modules/Invoke-AgentRunbook.ps1`.
- DLP and label provisioning scripts in `ClaudIA/modules/Configure-CoreDLP.ps1`, `Configure-DLP.ps1` and `Provision-SensitivityLabels.ps1`.

## Implementation Rule

Do not treat all `expectedSignals` as signals that must be produced natively by Microsoft 365 on day one.

Each action should explicitly declare one of these modes:

| Mode | Meaning |
|---|---|
| `LiveWebAction` | The BrowserAgent or Graph call performs the real action in Microsoft 365 Web or Graph. |
| `LiveWebActionWithDelayedSignal` | The action is real, but Purview/Defender signal arrival may lag or be inconsistent. |
| `SyntheticTelemetryCompanion` | The business action is simulated and a matching ADX event is emitted for dashboard/replay. |
| `SyntheticEndpointPlaceholder` | Endpoint-only behavior is represented as synthetic telemetry until VM/Windows 365 exists. |
| `ManualPresenterStep` | The action is best performed manually in a live demo until automation is stable. |

## Short-Term Scenario Set

Build these first:

| ScenarioId | Runner pattern | Notes |
|---|---|---|
| `BF-SCEN-0002` | SPO/Excel + Internal AI + ADX | Strongest Shadow AI story; use Devon. |
| `BF-SCEN-0013` | SPO/Excel + label change + Outlook | Best Purview label governance scenario. |
| `BF-SCEN-0001` | SPO/Office + Teams + Outlook | Best collaboration oversharing scenario. |
| `BF-SCEN-0023` | SPO/Excel + Outlook + Copilot | Raw vs anonymized vendor sharing. |
| `BF-SCEN-0024` | Outlook + SPO/PowerPoint | Executive wrong-audience story. |
| `BF-SCEN-0008` | SPO + Outlook + Teams | KYC vendor oversharing. |
| `BF-SCEN-0006` | Word/SPO + Teams + Outlook | Legal/regulatory premature sharing. |
| `BF-SCEN-0026` | Outlook + Teams | Customer support disclosure. |

## Recommended Runner Architecture

Prefer reusable action runners instead of creating 30 one-off scripts.

```text
scenario catalog
  -> action plan resolver
    -> persona context loader
      -> workload runner
        -> telemetry writer
```

Suggested runner families:

- `sharepointOfficeRunner`: create/open/upload/edit files in SharePoint or OneDrive.
- `outlookRunner`: compose internal/external email, attach file or share link, capture policy-tip text if available.
- `teamsRunner`: post channel/chat messages and links.
- `copilotRunner`: submit prompt to Copilot Web where license allows it; otherwise use synthetic AI event.
- `internalAiRunner`: use the existing Internal AI Workbench/Foundry fallback path.
- `purviewReviewRunner`: create investigation notes and ADX events for DLP/label/AI governance review.

## Telemetry Contract

Every emitted event should carry at least:

```text
EventId
TimeGenerated
ScenarioId
CorrelationId
PersonaName
UserPrincipalName
Workload
Operation
ImplementationMode
IsSynthetic
BusinessContext
FileName
SensitivityLabel
Recipient
TargetDomain
RiskScore
Severity
AdditionalProperties
```

For endpoint placeholders, include:

```text
ImplementationMode = SyntheticEndpointPlaceholder
EndpointDependency = VM_OR_WINDOWS_365_REQUIRED
DeviceId = DEV-FIC-2219
```

## Medium-Term Workload Additions

Add one workload runner at a time:

1. `listsRunner` for `BF-SCEN-0003` and `BF-SCEN-0012`.
2. `powerBiRunner` for `BF-SCEN-0004`, `BF-SCEN-0011`, `BF-SCEN-0015`, `BF-SCEN-0029`.
3. `formsRunner` for `BF-SCEN-0020` and `BF-SCEN-0028`.
4. `plannerRunner` for `BF-SCEN-0010` and `BF-SCEN-0028`.
5. `guestAccessRunner` for `BF-SCEN-0010`, `BF-SCEN-0019`, `BF-SCEN-0027`.
6. `loopWhiteboardStreamRunner` for `BF-SCEN-0016`, `BF-SCEN-0018`, `BF-SCEN-0021`.

## Long-Term Endpoint Boundary

Keep these actions synthetic until a managed endpoint exists:

- `FilePrinted`
- `FileCopiedToUSB`
- `FileCopiedToNetworkShare`
- `EndpointDLPPolicyMatch`
- Defender for Endpoint investigation events
- True risky sign-in and Conditional Access events

These scenarios should not block web implementation:

- `BF-SCEN-0005`
- `BF-SCEN-0009`
- `BF-SCEN-0022`
- `BF-SCEN-0025`
- `BF-SCEN-0030`

For `BF-SCEN-0030`, implement a web-only preview first and reserve the complete chain for the endpoint phase.

## Safety Constraints

- Use only synthetic values from the scenario pack.
- Use controlled test mailboxes or `.test` recipients for external-sharing simulation.
- Do not paste real customer, employee, legal, banking, payment, or credential data into Copilot, external AI, email, Teams, Forms, or files.
- Preserve Devon as ambiguous: risky, pressured, mistaken, or negligent, not automatically malicious.

## Suggested Next Commit Scope

The next implementation commit should be small:

1. Create an Ola 1 scenario catalog derived from the eight short-term scenarios.
2. Add a validator that checks `ScenarioId`, persona existence, synthetic markers and endpoint placeholders.
3. Extend BrowserAgents telemetry to include `ScenarioId`, `CorrelationId` and `ImplementationMode`.
4. Implement one end-to-end flow for `BF-SCEN-0002`.

## Implementation Status

The Ola 1 catalog and scheduled runner are now implemented in:

- `BrowserAgents/scenarios/banking-finance-wave1.json`
- `BrowserAgents/lib/bankingScenarioPack.js`
- `BrowserAgents/tests/banking-finance-wave1.spec.js`
- `BrowserAgents/scripts/run-scheduled.js`
- `tools/Invoke-BrowserAgentDaily.ps1`
- `tools/Invoke-BrowserAgentScheduledRun.ps1`
- `tools/Deploy-BrowserAgentScheduledJobs.ps1`

The scheduled service alias is `banking`. Default scheduled services are now:

```text
owa,copilot,banking
```

The first implementation is telemetry-first and web-scoped. It validates the 8 short-term scenarios, maps them to personas, emits ADX-ready events, and keeps endpoint-only behaviors out of Wave 1.
