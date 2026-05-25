# Reset-AgentPasswords.ps1

## Purpose

Resets one or more configured agent passwords, stores them in Key Vault, and optionally updates Automation variables that point to the password secret names.

## Execution

```powershell
.\tools\Reset-AgentPasswords.ps1 -All
.\tools\Reset-AgentPasswords.ps1 -Agent sofia.lopez -RevealPassword
.\tools\Reset-AgentPasswords.ps1 -All -AgentPassword 'LabPassword123!'
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `Agent`: one or more target agents.
- `All`: reset all configured agents.
- `AgentPassword`: explicit password.
- `RevealPassword`: prints the generated/password value.
- `SkipAutomationVariables`: skips Automation variable update.

## Installer Integration

Not called by `Install-AutonomousAgents.ps1`. Use when credentials drift or after adding storyline users.

