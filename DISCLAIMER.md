# DISCLAIMER - IMPORTANT

## Lab Use Only

This solution is designed exclusively for **lab, demo, and testing environments**. It is NOT suitable for production deployments.

## Security Risks

| Risk | Detail |
| --- | --- |
| **ROPC Authentication** | Resource Owner Password Credentials flow sends user passwords to Azure AD. This is a legacy OAuth flow that Microsoft plans to deprecate. |
| **MFA Bypass** | Agent accounts are excluded from Multi-Factor Authentication via a Conditional Access exclusion group. This reduces the security posture of the tenant. |
| **Stored Passwords** | Agent passwords are stored in Azure Automation encrypted variables. If the Automation Account is compromised, all agent accounts are exposed. |
| **Fictitious PII** | Generated content contains realistic but fake Personally Identifiable Information (NIR, IBAN, names, addresses). While fictitious, this data could be confused with real PII. |
| **Broad Graph Permissions** | The Entra app registration has delegated permissions for Sites.ReadWrite.All, Mail.ReadWrite, Files.ReadWrite.All, Chat.Create, ChannelMessage.Send. |
| **Prompt Content in Logs** | AI prompts and responses (containing fictitious PII) are logged in Log Analytics. Anyone with LA Reader access can view them. |

## Mitigations Applied

- Agent accounts have NO admin roles
- MFA exclusion is scoped to a specific security group (not all users)
- Passwords are encrypted in Azure Automation (not in Key Vault due to network policy issues)
- All generated data is clearly fictitious (AI-generated with temperature=0.9)
- Log Analytics access restricted by RBAC
- Sentinel analytics rules monitor for anomalous agent behavior

## Liability

The authors of this solution accept no responsibility for any security incident, data breach, or compliance violation resulting from the use of this solution in a production environment. Use at your own risk.

## Before Deploying

1. Ensure you have written approval to deploy in the target tenant
2. Confirm the tenant is designated as a lab/test environment
3. Review the agents.json configuration for appropriateness
4. Understand that ROPC may be deprecated by Microsoft at any time
