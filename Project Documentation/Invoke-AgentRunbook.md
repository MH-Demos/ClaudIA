# Invoke-AgentRunbook.ps1

## Purpose

Azure Automation runbook that executes the autonomous agent activity. It generates files, emails, Teams posts, Copilot-like prompts, labels content, scans for unlabeled files, and ingests telemetry into ADX.

## Execution

This script is deployed into Azure Automation by Step `5`. Local/on-demand validation is normally done through test scripts:

```powershell
.\tests\Test-SingleAgent.ps1 -Agent ana.rodriguez
.\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 5
```

Runbook parameters:

- `RunAsAgent`: optional specific agent SAM/UPN.
- `SendEmails`: enables email sending behavior.
- `SkipWeekendCheck`: bypasses weekend guard.
- `ActivityMode`: controls activity mode, commonly `full`.

## Installer Integration

Not directly executed by `Install-AutonomousAgents.ps1`; it is uploaded and published by `modules/Deploy-Runbook.ps1` in Step `5`.

## Configuration Sources

- Automation variable `AgentConfig`
- Automation variable `AgentEmailThreads`
- Automation variables `AgentPwdSecret-<sam>`
- Key Vault secrets for agent passwords and `agent-client-secret`
- ADX values merged from `Installation_definitions.json`

## Sensitivity Label Logic

Label assignment is department and file-type aware. High-risk HR maps to `Conf-HR`, Finance maps to `Conf-Finance`, Legal maps to `Highly Confidential/All Employees`, and other sensitive departments default to `Confidential/All Employees` for high-risk content. Lower-risk content generally maps to `General/All Employees`.

