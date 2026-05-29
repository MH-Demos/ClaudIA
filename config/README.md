# Config

This folder contains the configuration files that tell ClaudIA how to build and operate a lab tenant.

Think of this folder as the control plane for the demo. It defines the tenant, Azure infrastructure, personas, schedules, ADX settings, Activity Story Map settings, browser-agent settings, external AI simulation options, and localization patterns.

## Most Important Files

| File or folder | Purpose |
| --- | --- |
| `agents.json` | Main configuration file for tenant placeholders, Azure resources, ADX, Activity Story Map, BrowserAgents, schedules, features, Teams, personas, and external recipients. |
| `agents-schema.json` | Schema used to validate the structure of `agents.json`. |
| `installation-definitions` | Optional step-by-step installation definitions used by deployment scripts. |
| `locales` | Synthetic data generation patterns by geography or language. This is not the documentation translation system. |

## How To Think About `agents.json`

`agents.json` is not only a list of users. It describes the lab.

It includes:

- Tenant domain and tenant ID placeholders.
- Azure subscription and resource group values.
- Key Vault name and secret references.
- Azure OpenAI / Azure AI Foundry configuration.
- Azure Data Explorer configuration.
- Activity Story Map configuration.
- BrowserAgent configuration.
- Schedule definitions.
- Feature flags.
- External AI service simulations.
- Microsoft Teams collaboration structures.
- Synthetic personas and their activity patterns.
- Lab-approved external recipients.

## First-Time Configuration

Before running ClaudIA in your own lab:

1. Copy or edit `agents.json`.
2. Replace placeholder tenant values with your lab tenant values.
3. Replace placeholder Azure resource names with your lab resource names.
4. Confirm the persona UPNs match your lab tenant domain.
5. Store passwords and secrets in Azure Key Vault.
6. Store only Key Vault secret names or non-secret references in configuration files.
7. Run the prerequisite checker before deployment.

```powershell
.\prerequisites\Test-Prerequisites.ps1
```

## Secrets Rule

Do not place secrets in this folder.

Do not commit:

- Passwords.
- Client secrets.
- API tokens.
- Connection strings.
- Browser session files.
- Real tenant IDs for public samples.
- Production subscription IDs.
- Real customer or employee information.

Use Azure Key Vault for runtime secrets. Configuration files should reference secret names, not secret values.

## Persona Configuration

The `agents` array in `agents.json` defines synthetic users such as Alexander Meyer, Ana Rodriguez, Devon Reyes, and Priya Sharma.

Each persona can define:

- `sam`
- `displayName`
- `department`
- `jobTitle`
- `wave`
- `workload`
- `copilotLicense`
- `workingHours`
- `filesPerDay`
- `emailsPerDay`
- `topics`
- `keyVaultSecretName`

For the public persona explanation, see:

- [../docs/personas.md](../docs/personas.md)
- [../Storyline/profiles.md](../Storyline/profiles.md)

## Localization Note

The `config/locales` folder is for synthetic content generation patterns. It can help ClaudIA generate regionally different names, formats, terms, or scenarios.

It is not used for translating documentation.

Documentation translations should follow the pattern defined in [../docs/localization.md](../docs/localization.md).

## Public-Safety Check

Before publishing the repository or sharing a configuration file, run:

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

If the check finds a secret, tenant-specific value, generated log, or local artifact, remove it before publishing.
