# Select-ExistingUsers.ps1

## Purpose

Interactive picker used to select existing Entra ID users as autonomous agents instead of creating new lab users.

## Execution

```powershell
.\modules\Select-ExistingUsers.ps1 -Domain contoso.example
.\modules\Select-ExistingUsers.ps1 -Domain contoso.example -MaxAgents 12
```

Normally run through:

```powershell
.\Install-ClaudIA.ps1 -UseExistingUsers
```

## Parameters

- `Domain`: tenant domain.
- `MaxAgents`: maximum number of users to select.

## Installer Integration

Called by `Install-ClaudIA.ps1` during preselection and Step `1` when existing-user mode is selected.

## Output

Returns selected user objects that are written back into effective agent configuration and installation definitions.

