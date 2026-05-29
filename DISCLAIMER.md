# DISCLAIMER - IMPORTANT

## Lab Use Only

This solution is designed exclusively for **lab, demo, training, and testing environments**. It is NOT suitable for production deployments.

Do not deploy ClaudIA in a tenant that contains real users, production data, production mailboxes, regulated records, or business-critical workloads.

## Security Risks

| Risk | Detail |
| --- | --- |
| **ROPC Authentication** | Resource Owner Password Credentials flow sends user passwords to Microsoft Entra ID. This is a legacy OAuth flow and is not recommended for production use. |
| **MFA Bypass** | Agent accounts must be excluded from Multi-Factor Authentication through a tightly scoped Conditional Access exclusion group for unattended lab automation to work. |
| **Stored Secrets** | Agent passwords, app secrets, API tokens, and similar sensitive values must be stored in Azure Key Vault. If Key Vault access or the automation identity is compromised, lab identities and services may be exposed. |
| **Fictitious PII** | Generated content may contain realistic but fake personally identifiable information, financial data, legal content, or operational data. While fictitious, it could be confused with real data if not clearly governed. |
| **Broad Delegated Graph Permissions** | The Entra app registration uses delegated permissions required to emulate user activity across Microsoft 365 workloads. |
| **Prompt and Activity Logs** | AI prompts, responses, metadata, and generated activity may be logged for traceability and demo purposes. Restrict access to telemetry stores. |
| **Browser Sessions** | Browser automation may create local session state under ignored folders such as `BrowserAgents/.auth`. These files must never be committed or shared. |

## Mitigations Applied

- Agent accounts are standard users and must have **no admin roles**.
- MFA exclusion is scoped to a dedicated ClaudIA agent group, not all users.
- Runtime secrets are expected to be stored in Azure Key Vault.
- Automation variables should store non-secret configuration or Key Vault secret names, not plaintext secrets.
- Generated data is fictional and intended for lab storytelling only.
- Telemetry access should be restricted through Azure RBAC.
- Sentinel analytics and remediation patterns can help detect privilege escalation affecting agent accounts.
- Public repository safety checks are provided through `tools/Test-PublicRepoSafety.ps1`.

## Liability

The authors and maintainers of this solution accept no responsibility for any security incident, data breach, cost overrun, compliance violation, or tenant misconfiguration resulting from the use of this solution. Use at your own risk.

## Before Deploying

1. Ensure you have written approval to deploy in the target tenant.
2. Confirm the tenant is designated as a lab, demo, or test environment.
3. Review [docs/security.md](docs/security.md).
4. Review [config/agents.json](config/agents.json) and replace all placeholders with lab-safe values.
5. Store secrets in Azure Key Vault.
6. Understand that ROPC is not recommended for production and may stop being viable if platform behavior changes.
7. Run the public repository safety check before publishing or sharing the repository.

```powershell
.\tools\Test-PublicRepoSafety.ps1
```
