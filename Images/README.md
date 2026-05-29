# Images

This folder contains visual assets used by ClaudIA documentation, the Activity Story Map, persona profiles, service diagrams, and storyline material.

Images are part of the learning experience. ClaudIA uses visuals to help users understand personas, services, architecture, data movement, and security scenarios.

## Folder Structure

| Folder | Purpose |
| --- | --- |
| `Branding` | ClaudIA and MH Demos branding assets used by documentation and the Activity Story Map. |
| `Characters` | Persona images aligned with synthetic user display names. |
| `Services` | Service icons or visual references used in maps, diagrams, and storyline views. |

## Branding Model

ClaudIA is the open source project and platform.

MH Demos is the fictional company and Microsoft 365 tenant used to demonstrate one ClaudIA implementation.

Use ClaudIA branding for repository-level documentation and project visuals. Use MH Demos branding only when the visual represents the fictional tenant or implemented demo portal.

See [../docs/branding.md](../docs/branding.md).

## Character Images

Persona images should match the synthetic people defined in:

- [../docs/personas.md](../docs/personas.md)
- [../Storyline/profiles.md](../Storyline/profiles.md)
- [../config/agents.json](../config/agents.json)

Recommended convention:

```text
Images/Characters/Alexander Meyer.png
Images/Characters/Ana Rodriguez.png
Images/Characters/Devon Reyes.png
Images/Characters/Priya Sharma.png
```

The file base name should match the persona display name where possible. This makes it easier for scripts and portal publishing logic to map users to images.

## Publishing Images To The Activity Story Map

After changing images, run:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

If Azure Front Door is enabled and cached content does not refresh:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1 -PurgeFrontDoor
```

## Public-Safety Rules

Do not store or publish:

- Real employee photos for synthetic personas.
- Customer logos without permission.
- Screenshots exposing tenant IDs, subscription IDs, UPNs, tokens, or secrets.
- Production portal screenshots with sensitive records.
- Images containing credentials, QR codes, access tokens, or connection strings.

Use fictional personas, lab-safe screenshots, and generic identifiers.

## Visual Style Guidance

ClaudIA visuals should be:

- Clear.
- Modern.
- Technical.
- Human-centered.
- Consistent with the ClaudIA brand.
- Useful for explaining security and governance concepts.

Preferred themes include cloud activity, AI, telemetry, Microsoft 365-style governance, identity, data protection, and visual storytelling.
