# Activity Story Map - Technology Summary

## Overview

Activity Story Map is an educational portal designed to explain how simulated users, Microsoft 365 services, Azure resources, and AI-driven activity can be connected into a visual cybersecurity story.

The solution uses autonomous agents to emulate daily user behavior such as uploading documents, sending emails, collaborating in Teams, using SharePoint, interacting with Copilot-like experiences, and generating telemetry that can later support Purview, DLP, Insider Risk, and AI governance scenarios.

The goal is not only to generate activity, but to make that activity understandable for technical and non-technical audiences through a visual map, character profiles, service relationships, and a solution architecture view.

## Main Technologies Used

### Azure Automation

Azure Automation is used to execute the core autonomous agent runbook.

The runbook simulates user activities across Microsoft 365 workloads, generates files and messages, and sends normalized telemetry to Azure Data Explorer. It runs on a schedule so the demo environment can stay active without manual execution.

Key role in the project:

- Executes the main `Invoke-AgentRunbook` workflow.
- Simulates daily business activity for multiple personas.
- Runs scheduled refreshes two or three times per day.
- Coordinates Microsoft 365 activity, AI-generated content, and telemetry ingestion.

### Azure OpenAI

Azure OpenAI is one of the most important AI components in the solution.

It is used to generate realistic business content for documents, emails, reports, summaries, and collaboration scenarios. Instead of static demo data, the environment can produce contextual content aligned with each persona, department, and business scenario.

Key role in the project:

- Generates realistic document and email content.
- Supports narrative-driven security scenarios.
- Helps create data that can trigger DLP, sensitivity, governance, and investigation stories.
- Enables more natural demos around Copilot, oversharing, and AI-assisted work.

Current model reference:

- `gpt-4.1-mini`
- Model version: `2025-04-14`

### Azure AI Foundry and External AI Simulation

The project also includes scenarios associated with external or non-Copilot AI usage.

These activities are represented in the Activity Map as interactions with models such as Llama, Grok, Claude, and DeepSeek through Azure AI Foundry-style service nodes. This allows the story to show how users may interact with AI systems outside standard Microsoft 365 Copilot workflows.

Key role in the project:

- Represents non-Copilot AI usage.
- Supports AI data leakage and AI governance narratives.
- Helps compare sanctioned and unsanctioned AI activity.
- Provides visual differentiation between Microsoft 365 Copilot and external AI interactions.

### Microsoft 365 Copilot

Microsoft 365 Copilot is represented as part of the user activity and service usage story.

Some personas have Copilot licenses and others do not, allowing the demo to explain the impact of licensing, indexed content, oversharing, and AI-assisted productivity.

Key role in the project:

- Supports Copilot-related storytelling.
- Helps explain why data governance matters before enabling AI.
- Shows the relationship between users, content, permissions, and AI-generated insights.
- Provides a natural bridge into Microsoft Purview DSPM for AI, DLP, and Insider Risk conversations.

### Microsoft Graph

Microsoft Graph is used to interact with Microsoft 365 and Microsoft Entra data.

It supports user discovery, organizational relationships, manager/direct report mapping, and Microsoft 365 workload activity. This allows the Activity Story Map to show not only what users did, but who they are, who they report to, and how they fit into the organization.

Key role in the project:

- Reads Microsoft Entra user and manager relationships.
- Supports organizational chart generation.
- Enables Microsoft 365 workload interactions.
- Helps connect personas to real tenant identities.

### Microsoft Entra ID

Microsoft Entra ID provides the identity foundation for the demo.

Users, manager relationships, identity context, and application access are represented in the portal. Character profiles are enriched with Entra information so the demo can explain not only activity, but organizational context.

Key role in the project:

- Provides user identities.
- Stores manager/direct report relationships.
- Supports organization chart visualization.
- Provides identity context for Microsoft 365 and Azure access.

### Microsoft 365 Services

The demo uses several Microsoft 365 workloads to emulate realistic business activity.

Main services represented:

- SharePoint Online: document uploads, collaboration, file storage, and oversharing scenarios.
- OneDrive for Business: personal file activity and individual storage patterns.
- Exchange Online / Outlook: email and threaded communications.
- Microsoft Teams: chats, posts, meetings, and collaboration flows.
- Microsoft Lists: business tracking scenarios, backed by SharePoint.
- Microsoft Fabric: analytics and data-oriented scenarios.
- Microsoft 365 Copilot: AI-assisted work and search patterns.

These services are visualized in the Activity Map as part of the story of what users are doing and where data is moving.

## Data and Telemetry Layer

### Azure Data Explorer

Azure Data Explorer is the main telemetry store for the solution.

Every relevant agent activity is normalized and stored in ADX, especially inside the `CLAUDIA_Activity` table. The Activity Story Map queries ADX live through an Azure Function API.

Key role in the project:

- Stores normalized activity events.
- Enables fast KQL queries over demo activity.
- Provides the data backend for the Activity Map.
- Supports dashboards, validation, and operational troubleshooting.

Current ADX components:

- Cluster: `adx-claudia-lab`
- Database: `ADX-CLAUDIA`
- Table: `CLAUDIA_Activity`
- Retention: `365 days`

### ADX Workbook

An Azure Workbook is used for telemetry validation and operational visibility.

While the Activity Map is designed for storytelling, the workbook helps validate ingestion, activity counts, and data quality.

Key role in the project:

- Validates ADX ingestion.
- Helps troubleshoot agent runs.
- Provides operational visibility for the demo backend.

## Portal and API Layer

### Azure Functions

Azure Functions exposes the API used by the static portal.

The Function App queries ADX and returns activity data to the browser. It also exposes a lightweight visit counter endpoint used by the portal status bar.

Key role in the project:

- Serves `/api/graph`.
- Queries ADX using managed identity.
- Serves `/api/visits`.
- Keeps the static portal decoupled from ADX credentials.

### Azure Storage Static Website

Azure Storage hosts the static Activity Story Map portal.

The portal is a static web experience made of HTML, CSS, JavaScript, character images, service icons, and branding assets.

Key role in the project:

- Hosts the Activity Story Map UI.
- Hosts character images and service icons.
- Hosts branding assets for the welcome page.
- Provides a low-cost static web front end.

### Azure Function Storage

A separate Storage Account supports the Function App runtime.

It is also used to store the lightweight visit counter JSON used by the portal.

Key role in the project:

- Stores Azure Functions runtime data.
- Stores the visit counter summary.
- Supports the Function App backend.

## Azure RBAC, Managed Identity, and Secure Access

The solution uses Azure identities and RBAC-style access patterns to avoid placing secrets directly into the portal.

Important access patterns:

### Function App Managed Identity to ADX

The Azure Function uses a managed identity to query Azure Data Explorer.

This avoids exposing ADX credentials to the browser. The browser calls the Function API, and the Function queries ADX using its Azure identity.

Key benefits:

- No ADX secrets in frontend code.
- Centralized API access control.
- Clear separation between browser, API, and telemetry backend.

### Automation and Key Vault

Azure Key Vault stores secrets required by the automation layer.

The runbook retrieves required secrets from Key Vault instead of hardcoding credentials in scripts or config files.

Key benefits:

- Centralized secret management.
- Reduced credential exposure.
- Better separation between automation logic and sensitive values.

### Storage Access

Storage is used for two different purposes:

- Static website hosting for the portal.
- Function runtime and visit counter data.

The static website storage serves public web assets, while Function storage remains part of the backend runtime. This separation keeps the public portal simple while keeping runtime state on the backend side.

### Browser Agent Managed Identity

The browser-agent expansion uses a user-assigned managed identity.

This identity allows scheduled Container Apps jobs to access required Azure resources without embedding long-lived credentials.

Key benefits:

- Cleaner access model for containerized jobs.
- Better alignment with Azure RBAC.
- Easier rotation and governance compared to secrets embedded in code.

## Edge and Delivery Layer

### Azure Front Door

Azure Front Door is used as the virtualized edge in front of the static portal.

It provides a public endpoint and supports the custom domain strategy for the Activity Story Map.

Key role in the project:

- Serves the portal through an Azure edge endpoint.
- Supports the custom domain `activitymap.contoso.example`.
- Provides a cleaner entry point than the raw Storage static website URL.
- Separates the public user-facing URL from the underlying storage origin.

This is useful for educational demos because the audience can access a friendly portal URL while the backend architecture remains modular.

## Browser Automation Layer

### Azure App Testing Playwright Workspaces

The newer browser-agent layer uses Azure App Testing Playwright Workspaces to emulate more realistic browser-based user activity.

Regional workspaces are used to represent activity from different geographies:

- Americas: East US
- Europe: West Europe
- Asia: East Asia

Key role in the project:

- Supports realistic browser interaction scenarios.
- Adds geographic storytelling to user simulation.
- Expands beyond API/scripted activity into browser-driven activity.

### Azure Container Apps Jobs

Azure Container Apps Jobs run scheduled browser-agent workloads.

These jobs can execute browser automation periodically, such as morning, midday, and afternoon runs.

Key role in the project:

- Runs scheduled browser-agent activity.
- Uses containerized execution.
- Connects to Playwright workspaces.
- Sends telemetry back to ADX.

### Azure Container Registry

Azure Container Registry stores the browser-agent container images.

Key role in the project:

- Stores browser-agent runtime images.
- Provides images to Container Apps Jobs.
- Supports repeatable deployment of browser automation workloads.

### Log Analytics

Log Analytics is used by the Container Apps environment for operational logs.

This is separate from ADX, which is the primary activity telemetry store. Log Analytics is used for infrastructure/runtime logging, while ADX stores the demo activity story.

## Visualization Layer

### Activity Map

The Activity Map visualizes user activity as a graph.

It connects users, services, actions, files, recipients, AI prompts, and other targets. This helps explain user behavior visually instead of forcing the audience to read raw logs or runbooks.

### Solution Map

The Solution Map explains the architecture behind the demo.

It shows Azure resources, Microsoft 365 services, AI components, telemetry flow, browser agents, and portal dependencies.

Each component includes:

- Description
- Core activity
- Dependencies
- Region
- Status

### Know Your Characters

The character section explains the personas behind the activity.

It includes user profile details, manager relationships, licenses, technologies used, sensitive data exposure, and demo focus.

This helps connect the technical activity to a human-centered cybersecurity story.

## Why This Architecture Matters

This architecture combines AI, Microsoft 365, Azure automation, identity, telemetry, and visualization into a single educational experience.

Instead of showing isolated logs or static diagrams, the portal explains:

- Who the users are.
- What services they use.
- What activities they perform.
- Where data is stored.
- How telemetry is collected.
- How AI changes the security story.
- How Azure services are connected through identities, RBAC, and managed access.

The result is a demo platform that can support conversations about:

- Microsoft Purview
- DLP
- Insider Risk
- Microsoft Defender
- Microsoft Sentinel
- Copilot readiness
- AI governance
- Data security posture
- Secure adoption of AI

## Suggested Post Angle

This project is a practical example of how to turn security telemetry into a visual story.

It shows how Azure and Microsoft 365 can be combined to create a living demo environment where AI-generated activity, user behavior, identity context, and telemetry become understandable for business and technical audiences.

The most important idea is that cybersecurity demos should not only show alerts or configurations. They should explain the story behind the activity: who acted, what they touched, what AI was involved, where the data moved, and why governance matters.
