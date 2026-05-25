# Publish-ActivityStoryMapAssets.ps1

## Purpose

Copies character and service images into the Activity Story Map web asset folder, generates manifests, and uploads assets to the configured static website storage.

## Execution

```powershell
.\tools\Publish-ActivityStoryMapAssets.ps1
.\tools\Publish-ActivityStoryMapAssets.ps1 -ImagesRoot .\Images
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `ImagesRoot`: root image folder. Default `Images`.

## Installer Integration

Not called by `Install-ClaudIA.ps1`. Use after changing images or manifests.

## Inputs

- `Images/Characters`
- `Images/Services`

## Outputs

- `activity-story-map/web/images`
- `activity-story-map/web/images/manifest.json`

