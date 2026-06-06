# Security Considerations

ClaudIA is a lab, demo, training, and testing platform. It is not designed for production tenants or production data.

This guide explains the main security assumptions behind ClaudIA so operators understand the trade-offs before deploying it.

## Authentication Flow

<img width="1672" height="941" alt="ClaudIA - Authentication flow" src="https://github.com/user-attachments/assets/57f58af5-c7f4-488a-8c45-b360f51e7d14" />


```text
Install-ClaudIA.ps1
    |
    +-- Creates Entra App Registration (app-claudia-dataagent)
    |     - ROPC enabled for lab-only delegated user simulation
    |     - Delegated permissions, not application permissions for normal persona activity
    |     - Admin consent required
    |
    +-- Stores runtime secrets in Azure Key Vault
    |     - Agent passwords
    |     - App client secrets
    |     - API tokens where applicable
    |
    +-- Stores non-secret runtime references in Azure Automation variables
    |     - Tenant ID
    |     - App ID
    |     - Key Vault name
    |     - Key Vault secret names
    |     - Agent configuration JSON
    |
    +-- At runtime
          1. Automation managed identity reads required secrets from Key Vault.
          2. For each persona, ClaudIA requests a delegated token through ROPC.
          3. Persona activity runs under that persona's user identity.
          4. Activity is logged to Azure Data Explorer table CLAUDIA_Activity.
```

## Why ROPC Is Used

| Aspect | Detail |
| --- | --- |
| What | Resource Owner Password Credentials sends a username and password to the Microsoft identity platform token endpoint. |
| Why ClaudIA uses it | It enables delegated user simulation without interactive browser login for scheduled lab activity. |
| Risk | Persona passwords are used by automation and must be protected. |
| MFA limitation | ROPC cannot satisfy MFA. Lab persona accounts require a scoped Conditional Access exclusion. |
| Microsoft position | ROPC is not recommended for production use. Use ClaudIA only in lab environments. |
| Alternative | Application permissions are safer for unattended automation, but activity appears as the app rather than the user, which weakens user-attributed demo scenarios. |

## Critical Lab Boundary

Do not deploy ClaudIA in a production tenant.
<img width="2172" height="724" alt="ClaudIA - Warning" src="https://github.com/user-attachments/assets/24ec8db6-f478-458c-8ad5-4ffbf7fdcae7" />


A safe ClaudIA tenant should contain:

- Fictional users.
- Fictional data.
- Lab-only Azure resources.
- Lab-only Microsoft 365 workloads.
- Lab-approved external recipients.
- No production mailboxes.
- No real customer data.
- No real regulated records.

## Attack Surface And Mitigations

| Vector | Risk | Mitigation |
| --- | --- | --- |
| Key Vault compromised | Agent passwords, app secrets, or API tokens could be exposed. | Restrict Key Vault RBAC, monitor access, rotate secrets, and use lab-only credentials. |
| Automation Account compromised | A compromised automation identity may read Key Vault secrets or run lab activity. | Restrict Automation RBAC, use managed identity, monitor runbook changes, and avoid production scope. |
| Agent account compromised | An attacker could impersonate a synthetic employee. | Agents must have no admin roles, must be lab-only, and must remain scoped to the MFA exclusion group. |
| MFA exclusion group expanded | Real users or privileged users could bypass MFA. | Use a dedicated group, review membership, and never add admin accounts. |
| Entra app abused | Delegated Graph permissions could be misused in the lab tenant. | Use only a lab tenant, review consent, rotate secrets, and remove the app when decommissioning. |
| Telemetry accessed | Prompt text and generated fictional data may be visible in ADX or logs. | Restrict ADX, Log Analytics, Function App, and Storage access through RBAC. |
| Browser sessions leaked | Browser session files can provide access to lab personas. | Never commit `BrowserAgents/.auth`; treat local session state as sensitive. |

## Permissions Granted

### Entra App: Delegated, Admin-Consented

| Permission | Usage |
| --- | --- |
| `openid` | ROPC authentication. |
| `offline_access` | Token refresh where required. |
| `User.Read` | Read persona identity. |
| `Files.ReadWrite.All` | Upload or modify files in user context. |
| `Sites.ReadWrite.All` | Upload or modify SharePoint site content in user context. |
| `Mail.ReadWrite` | Read or write persona mailbox content. |
| `Mail.Send` | Send email as the persona. |
| `Chat.Create` | Create Teams 1:1 chats. |
| `Chat.ReadWrite` | Send Teams chat messages. |
| `ChannelMessage.Send` | Post in Teams channels. |
| `Team.ReadBasic.All` | Read basic Teams membership context. |
| `storage.azure.com/user_impersonation` | Write to OneLake / Fabric scenarios where enabled. |

### Automation Managed Identity: Azure RBAC

| Role | Scope | Usage |
| --- | --- | --- |
| Key Vault Secrets User | ClaudIA Key Vault | Read runtime secrets by secret name. |
| Cognitive Services OpenAI User | Azure OpenAI account | Generate synthetic content. |
| ADX Database Ingestor | ADX database | Ingest normalized activity telemetry. |
| Additional deployment roles | Lab resource group | Deploy and maintain lab infrastructure when required. |

### Function App Managed Identity

When the Activity Story Map is enabled, the Function App should query ADX through managed identity instead of exposing ADX credentials to the browser.

| Role | Scope | Usage |
| --- | --- | --- |
| ADX database viewer or equivalent query permission | ClaudIA ADX database | Query activity data for the portal API. |

### Remediation Runbook Graph Permissions

Where the privilege-escalation remediation pattern is enabled, the managed identity may need Graph application permissions such as:

| Permission | Usage |
| --- | --- |
| `Group.ReadWrite.All` | Remove privileged agent accounts from the MFA exclusion group. |
| `User.Read.All` | Read user properties and group memberships. |
| `RoleManagement.Read.Directory` | Check whether agents have directory role assignments. |

## MFA Exclusion Rules

The ClaudIA MFA exclusion exists only to support lab automation.

The following rule is mandatory:

> MFA-excluded ClaudIA agent accounts must remain standard users with no admin roles.

If an agent receives any privileged directory role, remove it from the MFA exclusion group immediately. The automation pattern can also include a Sentinel alert and remediation runbook to enforce this.

## Secret Management Rules

Runtime secrets belong in Azure Key Vault.

Do not store the following in Git, config files, screenshots, docs, issues, or chat:

- Agent passwords.
- Client secrets.
- API tokens.
- Connection strings.
- Browser session files.
- Real tenant IDs intended to remain private.
- Production subscription IDs.
- Real UPNs from production tenants.

Automation variables may store secret **names** and non-secret configuration. They should not store plaintext passwords or client secret values.

## Lab Operator Recommendations

1. Use a dedicated lab tenant.
2. Use dedicated synthetic users.
3. Keep agent accounts unprivileged.
4. Review the MFA exclusion group regularly.
5. Restrict Key Vault, Automation, ADX, Function App, and Storage access.
6. Rotate agent passwords and app secrets periodically.
7. Delete lab identities and resources when the environment is decommissioned.
8. Run the public repository safety check before publishing changes.

```powershell
.\tools\Test-PublicRepoSafety.ps1
```

## Decommissioning Guidance

When the lab is no longer needed:

1. Disable scheduled runbooks and Container Apps jobs.
2. Remove or disable persona accounts.
3. Remove persona accounts from MFA exclusion groups.
4. Delete app registrations created for ClaudIA if no longer needed.
5. Delete or purge Key Vault secrets.
6. Remove ADX tables or clusters if no longer required.
7. Remove public portal endpoints if they should no longer be reachable.
8. Validate that no generated data was copied into production locations.
