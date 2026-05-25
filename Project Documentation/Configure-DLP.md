# Configure-DLP.ps1

## Purpose

Configures DSPM for AI-oriented DLP policies in Purview. These policies focus on AI interactions, sensitive data exposure, and agent activity awareness.

## Execution

```powershell
.\modules\Configure-DLP.ps1 -Config $config -Domain contoso.example
```

Normally run by:

```powershell
.\Install-ClaudIA.ps1 -Step 6 -SkipPrerequisites -UseInstallationDefinitions
```

## Parameters

- `Config`: parsed effective config object.
- `Domain`: tenant domain.

## Installer Integration

Called by `Install-ClaudIA.ps1` in Step `6b`.

## Policies Created

- `DLP-CopilotStudio-PII-Monitor`
- `DSPM-AI-Labels-Restrict`
- `DSPM-AI-ClaudIAActivity-Audit`

## Categorization Context

This script complements `Configure-CoreDLP.ps1`. The core script categorizes sensitive data into groups such as payment card data, identity/personal data, health data, financial/tax information, credentials/secrets, legal/corporate information, and intellectual property/technical information. This DSPM script narrows the scenario toward AI exposure and agent-generated content, using tenant-local SIT resolution and policy names designed for AI and Copilot demos.

## Alternatives

Run only Step `6b` if core DLP already exists and only DSPM for AI policies need to be refreshed. If Security & Compliance PowerShell fails to connect, connect with `Connect-IPPSSession` manually and rerun.

