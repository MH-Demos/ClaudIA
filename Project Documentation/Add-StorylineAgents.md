# Add-StorylineAgents.ps1

## Purpose

Adds additional storyline personas from `Storyline/profiles.md` into the lab configuration and synchronizes credentials/configuration when requested.

## Execution

```powershell
.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles
.\tools\Add-StorylineAgents.ps1 -Search sofia -StoreInKeyVault -UpdateAutomationVariables
.\tools\Add-StorylineAgents.ps1 -AutoFromProfiles -ResetPassword -RevealPassword
```

## Parameters

- `ConfigPath`: path to `config/agents.json`.
- `ProfilesPath`: path to `Storyline/profiles.md`.
- `InstallationDefinitionsPath`: path to `config/Installation_definitions.json`.
- `Search`: filters profiles.
- `AutoFromProfiles`: imports without interactive selection.
- `ResetPassword`: resets selected agent passwords.
- `NoPasswordReset`: prevents password reset.
- `StoreInKeyVault`: stores generated/password values in Key Vault.
- `UpdateAutomationVariables`: updates Automation variable pointers.
- `AgentPassword`: explicit password to use.
- `RevealPassword`: prints generated password.

## Installer Integration

Not called by `Install-ClaudIA.ps1`. The installer prints a suggestion to run it for storyline expansion.

## Alternatives

Use `tools\Reset-AgentPasswords.ps1` after adding agents if password synchronization needs to be repaired.

