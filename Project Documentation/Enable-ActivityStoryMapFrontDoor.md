# Enable-ActivityStoryMapFrontDoor.ps1

## Purpose

Adds Azure Front Door Standard in front of the Activity Story Map static website and optionally prepares a custom domain with Azure-managed TLS.

The current design keeps the API as a direct Azure Function call from the browser through `config.js`; Front Door serves the static UI and assets.

## Execution

```powershell
.\tools\Enable-ActivityStoryMapFrontDoor.ps1
.\tools\Enable-ActivityStoryMapFrontDoor.ps1 -CustomDomain activitymap.contoso.example
.\tools\Enable-ActivityStoryMapFrontDoor.ps1 -WhatIf
```

## DNS Records

For `activitymap.contoso.example`, create or update these records in the `contoso.example` DNS zone:

```text
activitymap             CNAME   <Front Door endpoint hostname>
_dnsauth.activitymap    TXT     <Front Door validation token>
```

The TXT record validates ownership for the managed certificate. The CNAME sends browser traffic to Azure Front Door.

## Current Deployment

- Front Door profile: `afd-claudia-story`
- Endpoint: `https://claudia-storymap.azurefd.net/`
- Custom domain: `https://activitymap.contoso.example/`
- DNS CNAME target: `claudia-storymap.azurefd.net`
- DNS TXT name: `_dnsauth.activitymap`
- DNS TXT value: `<front-door-validation-token>`

