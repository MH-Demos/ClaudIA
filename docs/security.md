# Security Considerations

## Authentication Flow

```
Install-AutonomousAgents.ps1
    |
    +-- Creates Entra App Registration (app-dataagent)
    |     - ROPC enabled (Allow public client flows)
    |     - Delegated permissions (NOT application)
    |     - Admin consent granted
    |
    +-- Agent passwords stored in Azure Automation encrypted variables
    |     - NOT in Key Vault (Azure Policy blocks AA sandboxes from KV)
    |     - Encrypted at rest by Automation Account
    |
    +-- At runtime (runbook):
          1. Automation MI gets shared key from LA workspace
          2. For each agent: ROPC token with explicit delegated scopes
          3. Agent actions (file upload, email) under agent's own identity
          4. Activity logged to AgentActivity_CL via Data Collector API
```

## Why ROPC (and why it's risky)

| Aspect | Detail |
| --- | --- |
| **What** | Resource Owner Password Credentials: sends username + password to Azure AD token endpoint |
| **Why we use it** | Only way to get a **delegated token** (user identity) without interactive browser login |
| **Risk** | Passwords are sent to Azure AD (over TLS), stored in Automation Account |
| **MFA bypass** | ROPC cannot work with MFA -- agents must be excluded via Conditional Access |
| **Microsoft position** | ROPC is "not recommended" and may be deprecated. Use only for testing. |
| **Alternative** | Service principal + application permissions -- but audit logs show app identity, not user |

## Attack Surface

| Vector | Risk | Mitigation |
| --- | --- | --- |
| Automation Account compromised | All agent passwords exposed | AA RBAC restricted, no local auth, MI-only |
| Agent account compromised | Attacker can impersonate employee | Agents have NO admin roles, scoped CA exclusion |
| Entra app abused | Broad Graph permissions | Admin consent required, app scoped to delegated only |
| LA data accessed | Prompt content with fictitious PII visible | LA RBAC restricted, separate workspace from production |
| MFA exclusion group expanded | More users bypass MFA | Group is dedicated, auditable, review membership regularly |

## Permissions Granted

### Entra App (Delegated, admin-consented)

| Permission | Usage |
| --- | --- |
| `openid` | ROPC authentication |
| `offline_access` | Token refresh |
| `User.Read` | Get agent identity (/me) |
| `Files.ReadWrite.All` | Upload files to SharePoint |
| `Sites.ReadWrite.All` | Upload to SharePoint sites |
| `Mail.ReadWrite` | Read/write mailbox |
| `Mail.Send` | Send emails as agent (delegated) |
| `Chat.Create` | Create Teams 1:1 chats |
| `Chat.ReadWrite` | Send chat messages |
| `ChannelMessage.Send` | Post in Teams channels |
| `Team.ReadBasic.All` | List Teams memberships |
| `storage.azure.com/user_impersonation` | Write files to OneLake Lakehouse (Fabric) -- separate ROPC token with `https://storage.azure.com/.default` scope |

### Automation MI (Azure RBAC)

| Role | Scope | Usage |
| --- | --- | --- |
| Cognitive Services OpenAI User | oai-agents | Call GPT-4o-mini |
| Log Analytics Contributor | la-agents | Get shared key for Data Collector API |

### Automation MI (Graph App Permissions — for remediation runbook)

| Permission | Usage |
| --- | --- |
| `Group.ReadWrite.All` | Remove agents from MFA exclusion group |
| `User.Read.All` | List user properties and group memberships |
| `RoleManagement.Read.Directory` | Check if agents have admin role assignments |

## Recommendations for Lab Operators

1. **Review agent passwords** quarterly -- rotate via the runbook re-deployment
2. **Monitor the MFA exclusion group** -- ensure only agent accounts are members
3. **Check Sentinel alerts** -- the 5 analytics rules detect anomalous agent behavior and privilege escalation
4. **Delete agent accounts** when the lab is decommissioned
5. **Never promote agent accounts** to any admin role

> **CRITICAL: MFA-excluded accounts MUST remain standard users without ANY admin privilege.**
> Because agent accounts bypass MFA (required for ROPC), granting them admin roles (Global Admin, User Admin, Exchange Admin, etc.) would create a high-severity security risk: an attacker with the password could gain admin access without MFA challenge. The wizard creates agents as standard Member users with no directory roles. This is by design and must not be changed.

### Automated Privilege Escalation Detection + Remediation

The package deploys two components to enforce the no-admin constraint:

**1. Sentinel Analytics Rule: `Agent-Privilege-Escalation`**
- KQL monitors `AuditLogs` for `Add member to role` / `Add eligible member to role` targeting agent accounts
- Runs every 5 minutes, severity: High, MITRE: T1078 (Privilege Escalation)
- Creates a Sentinel incident when any agent is assigned an admin role

**2. Remediation Runbook: `Remediate-AgentPrivilegeEscalation`**
- Azure Automation runbook using Managed Identity (Graph: `Group.ReadWrite.All`, `User.Read.All`)
- Scans all MFA exclusion group members for directory role assignments
- **Auto-removes** any privileged agent from `grp-agent-mfa-exclusion`
- Result: the agent falls back under Conditional Access MFA enforcement immediately
- Can be triggered manually or linked to Sentinel automation rule

**Remediation flow:**
```
Admin assigns role to agent
    -> AuditLog: "Add member to role"
    -> Sentinel rule triggers (5 min)
    -> High severity incident created
    -> Remediation runbook runs
    -> Agent removed from MFA exclusion group
    -> Agent now requires MFA (ROPC auth will fail)
    -> Admin notified via Sentinel incident
```
