# Internal AI Workbench

The Internal AI Workbench is a browser-accessible lab portal for simulating non-Copilot AI usage through Edge/Playwright.

## URL

The portal is published with the Activity Story Map static site:

```text
https://stclaudiamap.z22.web.core.windows.net/internal-ai/index.html
```

Model selector query examples:

```text
?model=deepseek
?model=claude
?model=grok
?model=llama
?model=gemini
```

## BrowserAgent Service

Run a single model interaction for Devon:

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent devon.reyes -Services deepseek -Azure
```

Supported service aliases:

```text
internalai
externalai
foundry
deepseek
claude
grok
llama
gemini
```

## Telemetry

The BrowserAgent records the interaction in ADX as:

- `ActivityType`: `external_ai`
- `Action`: `AIAppInteraction`
- `Service`: model service name, such as `Azure AI Foundry - DeepSeek`
- `Provider`: `DeepSeek`, `Anthropic`, `xAI`, `Meta`, or `Google`
- `ModelFamily`: `deepseek`, `claude`, `grok`, `llama`, or `gemini`
- `RuntimeMode`: `BrowserPortalSimulation`
- uploaded document metadata such as `UploadedFileName`, `UploadedFileType`, `UploadedDocumentSensitivity`, and `UploadedDocumentLabel`

This validates the browser path and Activity Story Map telemetry. It does not mean Microsoft Purview natively captured the third-party AI interaction unless the real app path is covered by Purview-supported capture policies.

## Expand To Scheduled Users

To include this portal in the scheduled Azure jobs for all configured users:

```powershell
.\tools\Deploy-BrowserAgentScheduledJobs.ps1 `
  -Deploy `
  -EnvironmentName cae-browseragents-adx-347fa5e9 `
  -Services owa,copilot,internalai `
  -ExternalRecipient 'demo.recipient@example.com' `
  -SendEmail `
  -Sensitive `
  -WeekendActivityPercent 25
```

To test only Devon first:

```powershell
.\tools\Invoke-BrowserAgentDaily.ps1 -Agent devon.reyes -Services deepseek -Azure
.\tools\Get-BrowserAgentTelemetry.ps1 -SinceMinutes 30
```


