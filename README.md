# ClaudIA

**Cloud Activity, Usage & Data Intelligence Architecture**

ClaudIA is a public, lab-first reference architecture for building a synthetic Microsoft 365 and Microsoft Purview activity environment. It helps security, compliance, data governance, and AI adoption teams generate realistic cloud activity, usage telemetry, sensitive content signals, browser interactions, and storyline-driven investigation data without using production users or production data.

> Lab use only. Read [DISCLAIMER.md](DISCLAIMER.md) and [docs/security.md](docs/security.md) before deploying.

![ClaudIA architecture overview](docs/images/infographic-en.png)

## What ClaudIA Builds

ClaudIA brings together four layers:

| Layer | Purpose |
| --- | --- |
| Autonomous agents | Simulated employees that create Microsoft 365 activity across SharePoint, OneDrive, Outlook, Teams, Fabric, Copilot, and browser-based workflows. |
| Data protection scenarios | Synthetic DLP, sensitivity labeling, Insider Risk, DSPM for AI, Defender, Sentinel, ADX, and MDCA scenarios. |
| Storyline assets | Personas, character images, scenario packs, demo scripts, KQL samples, timelines, and presentation-ready narratives. |
| Portal and activity map | A static web experience and API layer that can explain the architecture, show the storyline, and surface generated activity. |

The repository is designed so a new user can start from a clean lab tenant, follow scripts and docs, and reproduce the environment with their own tenant, Azure subscription, Key Vault, and Microsoft 365 licenses.

## Public Repository Safety

This repository is intended to be public. It must not contain:

- Real tenant IDs, subscription IDs, app IDs, tokens, passwords, connection strings, or validation secrets.
- Browser session files such as `BrowserAgents/.auth`.
- Local environment files such as `.env`.
- Generated logs, output files, Playwright reports, or `node_modules`.

Runtime secrets belong in Azure Key Vault, Azure Automation encrypted variables, local environment variables, or ignored local files. Public configuration files use sample values such as `contoso.example`, `00000000-0000-0000-0000-000000000000`, and `kv-claudia-lab`.

Run this check before publishing:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

## Repository Map

| Path | Contents |
| --- | --- |
| [How to Start.md](How%20to%20Start.md) | End-to-end setup path for a new public user. |
| [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md) | Clean-tenant readiness guide for audit, Security Defaults, Conditional Access, demo users, photos, Activity Portal, and branding. |
| [config](config) | Tenant, agent, locale, ADX, activity map, and installation definition templates. |
| [modules](modules) | PowerShell modules used by the main installer. |
| [tools](tools) | Operational tools for ADX, browser agents, story map publishing, costs, and validation. |
| [prerequisites](prerequisites) | Workstation and cloud prerequisite checks. |
| [BrowserAgents](BrowserAgents) | Playwright-based browser persona agents. |
| [activity-story-map](activity-story-map) | Static portal, API functions, visual assets, and architecture map. |
| [Storyline](Storyline) | Characters, scenarios, demo flow, investigation narratives, and workshop material. |
| [Images](Images) | Character, service, and branding image assets used by the portal and storyline. |
| [synthetic-m365-purview-pack](synthetic-m365-purview-pack) | Synthetic M365/Purview content pack. |
| [docs](docs) | Focused technical documentation and operating guides. |
| [Project Documentation](Project%20Documentation) | Generated script reference and architecture documentation. |

## Quick Start

1. Open PowerShell 7 as Administrator.
2. Install Azure CLI, Node.js LTS, Git, and the required PowerShell modules.
3. Sign in to the target lab tenant with Azure CLI.
4. Review and customize [config/agents.json](config/agents.json).
5. Run the prerequisite checker.
6. Run the deployment wizard.

```powershell
az login --tenant contoso.onmicrosoft.com
az account set --subscription 11111111-1111-1111-1111-111111111111

.\prerequisites\Test-Prerequisites.ps1
.\Install-AutonomousAgents.ps1
```

For the complete setup path, including local tools, Azure subscription requirements, Microsoft 365 licensing, Key Vault usage, browser agents, images, and storyline replication, use [How to Start.md](How%20to%20Start.md). If the tenant is brand new, start with [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md).

## Localization Strategy

English is the source language for the public repository. Do not prefix English files with `eng-`. Keep the current folder structure and add future translations under locale-specific folders only when needed.

Recommended pattern:

```text
docs/
  security.md
  localization.md
  es/
    security.md
  fr/
    security.md
```

The `config/locales` folder is reserved for synthetic data generation locales such as FR, UK, US, and DE. It is not the documentation translation system.

See [docs/localization.md](docs/localization.md) for contribution rules.

## Working With Secrets

ClaudIA expects secrets to be resolved at runtime:

- Agent passwords: stored in Azure Key Vault or Automation encrypted variables, depending on the script flow.
- App secrets: stored in Key Vault and referenced by secret name.
- ADX ingestion credentials: stored in Key Vault or passed through local environment variables for local tests.
- Browser sessions: generated locally under `BrowserAgents/.auth` and never committed.

If a value would grant access to a tenant, subscription, app, storage account, database, API, or browser session, it does not belong in Git.

## Storyline And Images

The storyline is part of the product, not decoration. Public users should be able to understand:

- Who the personas are.
- Which activities each persona performs.
- Which security or compliance signal is created.
- Which Purview, Defender, Sentinel, ADX, or browser workflow validates the signal.
- Which images and portal assets support the demo narrative.

Start with [Storyline/profiles.md](Storyline/profiles.md), [Storyline/live_demo_runbook_defender_purview.md](Storyline/live_demo_runbook_defender_purview.md), and [activity-story-map/web](activity-story-map/web).

## Maintenance Rule

When adding new work to this repository:

1. Keep scripts and code comments in English.
2. Update the README or relevant docs in the same change.
3. Add setup steps to [How to Start.md](How%20to%20Start.md) when they affect new users.
4. Keep sample configuration generic.
5. Run `.\tools\Test-PublicRepoSafety.ps1` before publishing.
