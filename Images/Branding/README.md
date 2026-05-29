# Branding Assets

This folder stores visual assets used by ClaudIA documentation, the Activity Story Map, and presentation material.

## Naming Model

- **ClaudIA** is the project, architecture, repository, and open source platform.
- **MH Demos** is the fictional company and Microsoft 365 tenant used to demonstrate a live ClaudIA deployment.

Use ClaudIA branding for project-level documentation and public repository material.

Use MH Demos branding only when representing the fictional implemented tenant or demo company.

## Recommended Structure

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

Keep deployable assets compatible with the Activity Story Map publishing scripts. If the current publisher expects files directly under `Images/Branding`, keep the operational files there until nested brand-kit support is confirmed.

## Publishing Notes

After changing branding assets, republish the Activity Story Map assets:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
```

If Azure Front Door is enabled and cached assets do not refresh, run:

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1 -PurgeFrontDoor
```

## Safety Rules

Do not store:

- Real customer logos unless you have permission.
- Screenshots with tenant IDs, subscription IDs, user IDs, or secrets.
- Images containing real credentials, tokens, browser sessions, or production data.
- Real employee photos for synthetic personas.

All public-facing ClaudIA imagery should use fictional personas, fictional tenant context, and lab-safe visual material.
