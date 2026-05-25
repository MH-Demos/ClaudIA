# Test-AgentCredentials.ps1

## Purpose

Validates agent credentials, Key Vault secrets, app consent, and token acquisition. It can also reveal expected/actual values when explicitly requested for troubleshooting.

## Execution

```powershell
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez -RepairConsent
.\tests\Test-AgentCredentials.ps1 -Agent ana.rodriguez -RevealSecretValues
```

## Parameters

- `Agent`: target agent SAM/UPN. Mandatory.
- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `ExpectedClientSecret`: optional expected app secret for comparison.
- `ExpectedPassword`: optional expected password for comparison.
- `RepairConsent`: attempts consent repair/validation path.
- `RevealSecretValues`: prints secret values for troubleshooting.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. Use it after Step `5` or when agent login/runbook auth fails.

## Alternatives

Use `tools\Reset-AgentPasswords.ps1` if password mismatch is found.

