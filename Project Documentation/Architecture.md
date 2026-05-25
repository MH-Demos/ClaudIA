# Architecture

## High-Level Flow

1. `Install-ClaudIA.ps1` loads `config/agents.json`.
2. If available, `config/Installation_definitions.json` is merged as the effective installation state.
3. The installer validates prerequisites, creates or selects agent users, assigns licenses, creates an MFA exclusion group, registers `app-claudia-dataagent`, and deploys Azure resources.
4. Azure Automation runs `modules/Invoke-AgentRunbook.ps1` on schedule or on demand.
5. Each agent authenticates through ROPC, generates synthetic business content with Azure OpenAI, writes files/messages/emails through Microsoft Graph, applies sensitivity labels, and pushes telemetry to ADX.
6. Purview policies, IRM policies, ADX workbook, and Activity Story Map consume the generated activity for demo and validation.

## Required Components

- Microsoft Entra ID tenant with administrative access.
- Microsoft 365 licenses suitable for Exchange, SharePoint, OneDrive, Teams, Purview, DLP, sensitivity labels, and optionally Copilot.
- Azure subscription with resource group, Azure OpenAI, Azure Automation, Key Vault, and ADX.
- Local tools: PowerShell 7, Azure CLI, Microsoft Graph PowerShell, ExchangeOnlineManagement, Az modules where required.
- Optional: Fabric capacity if `infrastructure.fabricEnabled` is set to `true`.

## Current Azure Configuration

- Resource group: `rg-claudia-lab`
- Location: `westus`
- Automation Account: `aa-claudia-lab`
- Key Vault: `kv-claudia-lab`
- Azure OpenAI: `oai-claudia-lab`
- Chat deployment: `gpt-4.1-mini` version `2025-04-14`
- Image model: not configured
- ADX cluster: `adx-claudia-lab`
- ADX SKU: `Dev(No SLA)_Standard_E2a_v4`
- ADX database: `ADX-CLAUDIA`
- ADX table: `CLAUDIA_Activity`
- ADX mapping: `CLAUDIA_Activity_mapping`
- ADX retention: `365` days
- Workbook: `ClaudIA Activity Monitor`
- Activity Story Map Storage URL: `https://stclaudiamap.z22.web.core.windows.net/`
- Activity Story Map API: `https://func-claudia-story.azurewebsites.net`

## Microsoft 365 Configuration

- Collaboration team: `CorpLab - Departments`
- Departments configured: `HR`, `Finance`, `Legal`, `Engineering`, `Sales`
- Sensitivity label policy: `CorpLab-Labels-Policy`
- Labels: `General`, `Confidential`, `Conf-HR`, `Conf-Finance`, `Highly Confidential`
- MFA exclusion group: `grp-claudia-agent-mfa-exclusion`
- App registration: `app-claudia-dataagent`
- Runbook: `Invoke-AgentRunbook`

## Purview DLP and IRM Configuration

Core DLP policies are category-based and created in Step `6a`:

- `EXO Policy - CLAUDIA`
- `SPO Policy - CLAUDIA`
- `ODB Policy - CLAUDIA`
- `Teams Policy - CLAUDIA`
- `Endpoint Policy - CLAUDIA`
- `Copilot Policy - CLAUDIA`

DSPM for AI policies are created in Step `6b`:

- `DLP-CopilotStudio-PII-Monitor`
- `DSPM-AI-Labels-Restrict`
- `DSPM-AI-ClaudIAActivity-Audit`

IRM policies are created in Step `6c`:

- `IRM-DataLeaks-Lab`
- `IRM-RiskyAI-Lab`

## Where Variables Are Stored

- `config/agents.json`: source configuration for tenant, infrastructure, features, schedules, locales, and agent personas.
- `config/Installation_definitions.json`: generated installation state. It stores selected users, tenant IDs, resource names, ADX endpoints, run log path, deployed step results, and current effective values.
- Azure Automation variables:
  - `AgentTenantId`
  - `AgentAppId`
  - `AgentKeyVaultName`
  - `AgentClientSecretName`
  - `AgentConfig`
  - `AgentEmailThreads`
  - `AgentPwdSecret-<sam>`
  - ADX and collaboration values when provisioned by modules.
- Azure Key Vault secrets:
  - `agent-client-secret`
  - One secret per agent, for example `ana-rodriguez`, `carlos-delgado`, `sofia-lopez`.
- Local logs:
  - `logs/Install-ClaudIA-<timestamp>.log`
- Story Map static assets:
  - `activity-story-map/web`
  - `activity-story-map/web/images`
  - `Images/Characters`
  - `Images/Services`

## Security Notes

This project is for lab and demo use. It uses ROPC for delegated agent activity, which bypasses MFA and should not be used in production. Passwords and app secrets are kept in Key Vault; Automation variables store secret names and non-secret configuration, not the password values.

