# ClaudIA

**Cloud Activity, Usage & Data Intelligence Architecture**

ClaudIA is an open source, lab-first platform for creating a **living Microsoft 365 tenant**: synthetic employees work, collaborate, generate content, interact with AI, trigger security signals, and leave telemetry that can be explored through Microsoft Purview, Microsoft Defender, Azure Data Explorer, and the ClaudIA Activity Story Map.

ClaudIA is designed for people who need a realistic Microsoft 365 environment for demos, learning, workshops, security research, governance storytelling, and AI-readiness conversations without using production users or production data.

> Lab use only. Read [DISCLAIMER.md](DISCLAIMER.md) and [docs/security.md](docs/security.md) before deploying.

![ClaudIA architecture overview](docs/images/infographic-en.png)

## New To AI, Azure, Or Microsoft 365?

Start here before deploying anything:

- [docs/learn-from-scratch.md](docs/learn-from-scratch.md) — beginner learning path for students and first-time users.
- [docs/glossary.md](docs/glossary.md) — simple definitions for AI, Microsoft 365, Azure, Purview, Defender, MDCA, Key Vault, agents, telemetry, sessions, memory, context, and more.
- [docs/personas.md](docs/personas.md) — explanation of ClaudIA's fictional employees and why they matter.

ClaudIA can be used in two ways:

1. **As an educational portal** to understand AI, cloud activity, data security, governance, and Microsoft 365 concepts.
2. **As a deployable lab architecture** to create a working synthetic Microsoft 365 environment.

If you are new, use it first as a learning portal. Deploy it only after you understand the lab-only security model.

## What ClaudIA Is

ClaudIA helps you build a Microsoft 365 lab where simulated users behave like a real organization. Instead of showing isolated scripts, static files, or empty portals, ClaudIA creates a repeatable environment where identity, collaboration, data, AI usage, telemetry, and security controls can be connected into a story.

The goal is simple:

> Make Microsoft 365 security and governance easier to understand by showing real-looking activity from fictional users in a controlled lab tenant.

## What ClaudIA Builds

| Layer | Purpose |
| --- | --- |
| Synthetic personas | Thirteen fictional employees with roles, relationships, workloads, and demo purposes. |
| Microsoft 365 activity | SharePoint, OneDrive, Outlook, Teams, Microsoft Lists, Fabric, Copilot-style, and browser-driven workflows. |
| Data protection scenarios | DLP, sensitivity labels, Insider Risk, DSPM for AI, Defender, Sentinel, ADX, and MDCA-oriented scenarios. |
| AI interaction patterns | Microsoft 365 Copilot-oriented scenarios and controlled external AI simulations for AI governance discussions. |
| Telemetry layer | Normalized activity events stored in Azure Data Explorer for analysis, validation, and visualization. |
| Activity Story Map | A visual portal that explains users, services, activities, relationships, architecture, and generated signals. |

## Who This Is For

ClaudIA is useful for:

- Students who are beginning to learn AI, cloud, Microsoft 365, cybersecurity, or data governance.
- Microsoft 365 security, compliance, data governance, and AI adoption teams.
- Consultants and architects who need repeatable demos.
- Trainers who want a tenant that feels active instead of empty.
- Builders who want to learn Azure Automation, Key Vault, managed identities, RBAC, ADX, Microsoft Graph, Playwright, and portal-based storytelling.
- Teams preparing Microsoft Purview, Defender, Sentinel, Copilot readiness, DLP, Insider Risk, or AI governance workshops.

## Public Demo Context

**ClaudIA** is the project and open source platform.

**MH Demos** is the fictional company and Microsoft 365 tenant used to demonstrate one implemented ClaudIA environment.

A public implementation of the Activity Story Map is available at:

https://activitymap.mhdemos.com

## Start Here

| Goal | Start with |
| --- | --- |
| Learn from zero | [docs/learn-from-scratch.md](docs/learn-from-scratch.md) and [docs/glossary.md](docs/glossary.md) |
| Understand the concept | [docs/personas.md](docs/personas.md), [docs/branding.md](docs/branding.md), and [Project Documentation/ActivityStoryMap_Technology_Post_Summary.md](Project%20Documentation/ActivityStoryMap_Technology_Post_Summary.md) |
| Deploy the lab | [How to Start.md](How%20to%20Start.md) |
| Prepare a brand-new tenant | [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md) |
| Review security risks | [DISCLAIMER.md](DISCLAIMER.md) and [docs/security.md](docs/security.md) |
| Understand personas and storylines | [Storyline/profiles.md](Storyline/profiles.md) and [docs/personas.md](docs/personas.md) |
| Understand localization rules | [docs/localization.md](docs/localization.md) |
| Understand Codex-assisted development | [docs/codex-assisted-development.md](docs/codex-assisted-development.md) |

## Quick Start

Use a non-production Microsoft 365 tenant and an Azure subscription intended for lab use.

```powershell
az login --tenant contoso.onmicrosoft.com
az account set --subscription 11111111-1111-1111-1111-111111111111

.\prerequisites\Test-Prerequisites.ps1
.\Install-ClaudIA.ps1
```

For the complete setup path, including local tools, Azure subscription requirements, Microsoft 365 licensing, Key Vault usage, browser agents, images, and storyline replication, use [How to Start.md](How%20to%20Start.md). If the tenant is brand new, start with [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md).

## Repository Map

| Path | Contents |
| --- | --- |
| [How to Start.md](How%20to%20Start.md) | End-to-end setup path for a new public user. |
| [If Your Tenant Is Completely New.md](If%20Your%20Tenant%20Is%20Completely%20New.md) | Clean-tenant readiness guide for audit, Security Defaults, Conditional Access, demo users, photos, Activity Portal, and branding. |
| [config](config) | Tenant, agent, locale, ADX, activity map, and installation definition templates. |
| [modules](modules) | PowerShell modules used by the main installer. |
| [tools](tools) | Operational tools for ADX, browser agents, story map publishing, costs, and validation. |
| [UpdateInfo](UpdateInfo) | Script version manifest used by `tools/Update-ClaudIAScripts.ps1`. |
| [prerequisites](prerequisites) | Workstation and cloud prerequisite checks. |
| [BrowserAgents](BrowserAgents) | Playwright-based browser persona agents. |
| [activity-story-map](activity-story-map) | Static portal, API functions, visual assets, and architecture map. |
| [Storyline](Storyline) | Characters, scenarios, demo flow, investigation narratives, and workshop material. |
| [Images](Images) | Character, service, and branding image assets used by the portal and storyline. |
| [synthetic-m365-purview-pack](synthetic-m365-purview-pack) | Synthetic M365/Purview content pack. |
| [docs](docs) | Focused technical documentation and operating guides. |
| [Project Documentation](Project%20Documentation) | Generated script reference and architecture documentation. |

## The ClaudIA Personas

ClaudIA uses thirteen synthetic personas connected through an organizational model:

```text
Alexander Meyer
├── Emily Johnson
├── James Wilson
│   ├── Diego Martinez
│   │   ├── Carlos Delgado
│   │   └── Sofia Lopez
│   └── Laura Gomez
│       ├── David Chen
│       └── Miguel Santos
└── Marcus Olsson
    └── Ana Rodriguez
        ├── Devon Reyes
        └── Priya Sharma
```

Devon Reyes is intentionally used for controlled risky, suspicious, or incorrect behavior from a security perspective. Devon is not an external attacker; he is a fictional internal persona used to generate investigation material for DLP, Insider Risk, Shadow AI, and security storytelling.

See [docs/personas.md](docs/personas.md) and [Storyline/profiles.md](Storyline/profiles.md).

## Working With Secrets

ClaudIA expects secrets to be resolved at runtime from **Azure Key Vault**.

- Agent passwords are stored in Key Vault by secret name.
- App secrets are stored in Key Vault by secret name.
- ADX ingestion credentials are stored in Key Vault or provided through secure runtime mechanisms for local tests.
- Browser sessions are generated locally under `BrowserAgents/.auth` and never committed.
- Automation variables should store non-secret configuration or references to Key Vault secret names, not plaintext secrets.

If a value would grant access to a tenant, subscription, app, storage account, database, API, mailbox, or browser session, it does not belong in Git.

## Public Repository Safety

This repository is intended to be public. It must not contain:

- Real tenant IDs, subscription IDs, app IDs, tokens, passwords, connection strings, or validation secrets.
- Browser session files such as `BrowserAgents/.auth`.
- Local environment files such as `.env`.
- Generated logs, output files, Playwright reports, or `node_modules`.

Run this check before publishing:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

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

## Built With AI-Assisted Engineering

Large portions of ClaudIA were designed, documented, and accelerated with OpenAI Codex as an engineering assistant. Codex helped generate documentation, scripts, refactoring plans, implementation guidance, and review checklists. Human maintainers remain responsible for reviewing, validating, securing, and governing the project.

See [docs/codex-assisted-development.md](docs/codex-assisted-development.md).

## Maintenance Rule

When adding new work to this repository:

1. Keep scripts and code comments in English.
2. Update the README or relevant docs in the same change.
3. Add setup steps to [How to Start.md](How%20to%20Start.md) when they affect new users.
4. Keep sample configuration generic.
5. Store secrets in Azure Key Vault or a secure runtime mechanism; never store them in Git.
6. Run `.	ools\Test-PublicRepoSafety.ps1` before publishing.
