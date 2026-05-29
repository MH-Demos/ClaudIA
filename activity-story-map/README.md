# Activity Story Map

The Activity Story Map is ClaudIA's visual learning portal.

It helps users understand how synthetic personas, Microsoft 365 services, Azure resources, AI interactions, telemetry, and security signals connect into one story.

Instead of asking a new user to read raw logs or scripts first, the Activity Story Map shows:

- Who the personas are.
- What services they use.
- Which activities they perform.
- Which files, messages, prompts, or recipients are involved.
- How activity flows into Azure Data Explorer.
- How the architecture supports Purview, Defender, Sentinel, DLP, Insider Risk, and AI governance demos.

## ClaudIA vs. MH Demos

ClaudIA is the open source platform.

MH Demos is the fictional company and Microsoft 365 tenant used to demonstrate one ClaudIA implementation.

A public implementation is available at:

https://activitymap.mhdemos.com

## Folder Purpose

This folder contains the static web portal, supporting API assets, activity visualization code, visual assets, and architecture/story map content used to explain a running ClaudIA environment.

Typical responsibilities:

- Static portal pages.
- JavaScript activity graph logic.
- Persona and service visualizations.
- Architecture map views.
- API integration with Azure Functions.
- Published image references.
- Storyline navigation.

## Architecture Overview

The portal follows a simple pattern:

```text
Browser
  -> Static website assets
  -> Azure Function API
  -> Azure Data Explorer
  -> CLAUDIA_Activity table
```

The browser should not connect directly to ADX or hold ADX credentials. The API layer queries ADX through managed identity or a secure backend access model.

## Related Azure Components

| Component | Purpose |
| --- | --- |
| Azure Storage Static Website | Hosts the static portal. |
| Azure Functions | Provides API endpoints for graph/activity data. |
| Azure Data Explorer | Stores normalized ClaudIA activity events. |
| Azure Front Door | Optional friendly public endpoint and caching layer. |
| Key Vault | Stores runtime secrets used by backend components where applicable. |

## Publishing Assets

After updating images, branding, personas, or service icons, publish the assets from the repository root:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

If Azure Front Door is enabled and cached assets need to refresh:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1 -PurgeFrontDoor
```

## Configuration

Activity Story Map configuration is controlled from `config/agents.json`, especially the `activityStoryMap` section.

Typical values include:

- Whether the portal is enabled.
- Storage account name.
- Function App name.
- API base URL.
- Static website URL.
- Optional Front Door settings.
- ADX cluster, database, and table references.

Do not store secrets in the web app or static JavaScript files.

## Public Portal Safety

Before publishing a public portal, confirm that it does not expose:

- Real tenant IDs.
- Real subscription IDs.
- Real user IDs.
- Real customer data.
- Secrets, tokens, or connection strings.
- Production screenshots.
- Browser session state.
- Sensitive internal URLs.

Use fictional personas and lab-safe data only.

## Learning Purpose

The portal should help both technical and non-technical audiences understand the story behind activity:

- Identity context.
- Data movement.
- AI usage.
- Oversharing.
- DLP and Insider Risk patterns.
- Telemetry ingestion.
- Investigation flow.
- Governance and secure AI adoption.

When adding a new feature to the portal, update the relevant documentation so a new user can understand what the visual component means and how it connects to the rest of ClaudIA.
