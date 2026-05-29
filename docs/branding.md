# Branding

ClaudIA and MH Demos are related, but they are not the same thing.

## Naming Model

| Name | Meaning |
| --- | --- |
| **ClaudIA** | The open source project, platform, architecture, brand, and documentation identity. |
| **MH Demos** | The fictional company and Microsoft 365 tenant used to demonstrate a live ClaudIA deployment. |

Use **ClaudIA** when referring to the project, scripts, architecture, documentation, repository, and open source platform.

Use **MH Demos** when referring to the fictional company represented inside the demo tenant, the simulated organization, or the public implemented environment.

## Public Demo Portal

A public implementation of the ClaudIA Activity Story Map is available at:

https://activitymap.mhdemos.com

This portal represents the MH Demos fictional tenant running a ClaudIA-powered activity map.

## Brand Meaning

ClaudIA means:

> Cloud Activity, Usage & Data Intelligence Architecture

The name reflects the core purpose of the project:

- **Cloud Activity**: simulated Microsoft 365 and browser-based activity.
- **Usage**: realistic service usage across users, teams, and workloads.
- **Data Intelligence**: sensitive content, telemetry, governance signals, and investigation data.
- **Architecture**: Azure, Microsoft 365, identity, automation, telemetry, and visualization working together.

## Visual Direction

The ClaudIA visual identity should feel:

- Modern.
- Technical.
- Educational.
- Microsoft 365-inspired, without copying Microsoft product branding.
- Secure and trustworthy.
- Human-centered, because personas and stories are part of the platform.

Preferred visual themes:

- Deep navy backgrounds.
- Electric cyan and purple gradients.
- Cloud, circuit, AI, telemetry, and governance motifs.
- Clean diagrams and visual maps.
- Persona-driven storytelling assets.

Avoid:

- Hacker clichés.
- Real customer logos.
- Real employee photos.
- Production tenant screenshots that expose identifiers.
- Branding that makes MH Demos look like the project name.

## Asset Locations

| Path | Purpose |
| --- | --- |
| `Images/Branding` | Public branding assets used by the Activity Story Map and documentation. |
| `Images/Characters` | Persona images aligned with synthetic user display names. |
| `Images/Services` | Service icons used by the portal and storyline. |
| `activity-story-map/web/images` | Published image assets consumed by the static portal. |

The Activity Story Map publisher builds image references from file names. Keep names clear, stable, and aligned with personas or services.

## Recommended Brand Kit Structure

Use this structure when organizing curated ClaudIA assets:

```text
Images/
  Branding/
    ClaudIA/
      README.md
      logo-claudia-transparent.png
      logo-claudia-dark-bg.png
      brand-board.png
      welcome-to-claudia.png
      open-source-banner.png
```

Keep deployable files compatible with the existing publishing scripts. If a script expects a file directly under `Images/Branding`, keep a copy or alias there until the publisher supports nested brand-kit folders.

## Documentation Wording

Recommended wording:

> ClaudIA is the open source platform. MH Demos is the fictional company used to demonstrate ClaudIA in action.

Avoid wording such as:

> MH Demos is ClaudIA.

or:

> ClaudIA is only a tenant.

ClaudIA is the platform. MH Demos is one implemented storyline and tenant environment.
