# Troubleshooting

> Last updated: v2.1 (2026-05-07)

## Common Issues

### ROPC returns 400 Bad Request

**Symptom**: `AADSTS50126: Invalid username or password`

**Cause**: Agent password stored in Automation variables doesn't match the actual user password.

**Fix (v2.1+)**: Re-run the wizard — it detects existing users and offers to auto-reset passwords:
```powershell
.\Install-AutonomousAgents.ps1 -SkipPrerequisites
# When prompted "Reset all agent passwords now? (Y/n)" → Y
# The wizard resets all 10 passwords and stores them in Automation variables automatically
```

**Fix (manual)**:
```powershell
# Reset password via Graph API
$gt = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$body = @{passwordProfile=@{password='<new-agent-password>';forceChangePasswordNextSignIn=$false}} | ConvertTo-Json
Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/amoreau@TENANT.onmicrosoft.com" `
    -Headers @{Authorization="Bearer $gt"; 'Content-Type'='application/json'} -Body $body
# Then update the Automation variable
```

### ROPC returns AADSTS50079 (MFA Required)

**Cause**: Agent is not in the MFA exclusion group, or the CA policy exclusion was not saved.

**Fix**:
1. Verify agent is member of `grp-agent-mfa-exclusion`
2. Entra admin center > Conditional Access > Edit MFA policy > Exclude > Verify the group is listed
3. Save the policy

### Activity Explorer shows "guest" instead of agent name

**Cause**: The ROPC token uses `.default` scope which returns an application token.

**Fix**: The runbook should use explicit delegated scopes (already configured in the packaged version). If you see "guest" after deployment, ensure the runbook is the latest version:
```powershell
.\modules\Deploy-Runbook.ps1 -Config $config -AgentPassword $pwd
```

### AgentActivity_CL table empty in Log Analytics

**Cause 1**: Automation MI doesn't have `Log Analytics Contributor` role.
```powershell
$aaObjId = az automation account show --name aa-agents -g rg-agents-lab --query identity.principalId -o tsv
az role assignment create --role "Log Analytics Contributor" --assignee-object-id $aaObjId `
    --assignee-principal-type ServicePrincipal --scope "/subscriptions/.../workspaces/la-agents"
```

**Cause 2**: Data Collector API takes 5-15 minutes for first-time table creation. Wait and re-check.

**Cause 3**: Weekend -- the runbook skips weekends by default. Use `-SkipWeekendCheck` parameter.

### OneLake upload fails (403 Forbidden)

**Symptom**: `Write-OneLake` logs `OneLake upload failed: 403` in runbook output.

**Cause 1**: Missing `storage.azure.com/user_impersonation` scope on the Entra app.
```powershell
# Add scope via Graph API (see customization.md > Enabling OneLake dual-write)
```

**Cause 2**: Admin consent not granted for the storage scope.

**Cause 3**: Fabric F2 capacity is paused.
```powershell
az resource invoke-action --action resume --resource-type "Microsoft.Fabric/capacities" \
    --name fabriclabcap --resource-group rg-security-lab
```

### OneLake variables not found

**Symptom**: Runbook runs but no OneLake output (only SharePoint uploads).

**Cause**: `AgentFabricWorkspaceId` and/or `AgentFabricLakehouseId` Automation variables missing.

**Fix**: Create the variables (see customization.md) and ensure they are in the same RG as the Automation Account. The wizard (v1.5.2+) auto-detects the correct RG.

### User creation says [OK] but users don't exist

**Symptom**: Step 1 shows `[OK]` for all users but Step 2 can't find them.

**Cause**: Pre-v1.4 bug -- `az ad user create` with `--department`/`--job-title` flags fails silently when errors are redirected to `$null`.

**Fix**: Update to v1.4+ which removes unsupported flags and checks `$LASTEXITCODE`.

### Sentinel onboarding fails (409 Conflict or 400 Bad Request)

**Symptom**: Step 4 shows `[WARN]` for Sentinel with 409 or 400 error.

**Cause**: Managed Environment (ME/MCAP) tenants block Sentinel onboarding via API. This is a platform restriction, not a code bug.

**Workaround**:
1. The remediation runbook still deploys and works in scan mode (no Sentinel trigger)
2. Use an external Sentinel workspace in a different subscription:
   ```json
   "sentinelWorkspace": "la-soc-prod",
   "sentinelResourceGroup": "rg-soc"
   ```
3. Or schedule the remediation runbook to run hourly as a standalone guard

### Agent removed from MFA exclusion group unexpectedly

**Symptom**: Agent ROPC auth fails with `AADSTS50079` (MFA required) after working previously.

**Cause**: The `Remediate-AgentPrivilegeEscalation` runbook detected an admin role on the agent and removed it from the MFA exclusion group as a security measure.

**Fix**:
1. Check the Sentinel incident `Agent-Privilege-Escalation` for details
2. Remove any admin role from the agent account
3. Re-add the agent to `grp-agent-mfa-exclusion` (only after role is removed)
4. Verify: the agent must have ZERO directory roles before re-adding to the exclusion group

### Key Vault Forbidden errors

**Cause**: Azure Policy on Managed Environment subscriptions blocks KV data plane access from Automation sandboxes.

**Fix**: This package uses Automation encrypted variables instead of Key Vault. If you see KV errors, the runbook is outdated -- re-deploy with:
```powershell
.\modules\Deploy-Runbook.ps1 -Config $config -AgentPassword $pwd
```

### Azure OpenAI returns 403

**Cause**: Automation MI doesn't have `Cognitive Services OpenAI User` role on the OpenAI resource.

**Fix**:
```powershell
$aaObjId = az automation account show --name aa-agents -g rg-agents-lab --query identity.principalId -o tsv
$oaiId = az cognitiveservices account show -n oai-agents -g rg-agents-lab --query id -o tsv
az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $aaObjId `
    --assignee-principal-type ServicePrincipal --scope $oaiId
```

### Content Explorer empty (no files visible)

**Cause**: SharePoint content crawler takes up to 7 days to index new sites. This is a Microsoft backend process.

**Workaround**:
1. SharePoint Admin Center > Active Sites > your site > Reindex (if available)
2. Check Activity Explorer instead (real-time audit data)
3. Wait 24-72h for the initial crawl

### Runbook stops after 30 minutes

**Cause**: Azure Automation Free tier has a 30-minute job timeout.

**Fix**: Upgrade to Basic tier:
```powershell
$body = @{properties=@{sku=@{name='Basic'}}} | ConvertTo-Json -Depth 3
Invoke-RestMethod -Method PATCH -Uri ".../automationAccounts/aa-agents?api-version=2023-11-01" `
    -Headers $h -Body $body
```

### Sentinel rules show no incidents

**Cause**: Custom rules reference `AzureDiagnostics` but agent data is in `AgentActivity_CL`.

**Fix**: Update Sentinel rules to query `AgentActivity_CL` instead. The packaged Sentinel rules are already configured correctly.

## Logs and Diagnostics

| Source | How to access | What it shows |
| --- | --- | --- |
| Automation job output | Azure Portal > Automation > Jobs > Output | Real-time agent activity |
| Automation job streams | Azure Portal > Automation > Jobs > Errors/Warnings | ROPC failures, API errors |
| AgentActivity_CL | LA > Logs > `AgentActivity_CL` | Agent UPN, activity type, prompt, response |
| AzureDiagnostics | LA > Logs > `AzureDiagnostics` | OpenAI API metadata (no user field) |
| Activity Explorer | Purview Portal > Activity Explorer | DLP matches, label activity (shows "guest" for AI) |
| Sentinel Incidents | Azure Portal > Sentinel > Incidents | Anomalous agent behavior alerts |

## Step 4a: M365 Collaboration Issues

### Teams team creation fails

**Symptom**: `POST /v1.0/teams` returns 403 or 400

**Cause**: The admin account doesn't have Teams admin role, or Teams is not provisioned in the tenant.

**Fix**:
1. Ensure your admin account has Teams Administrator or Global Admin role
2. Verify Teams is enabled: `Get-CsTeamsClientConfiguration` (requires Teams PowerShell)
3. If multiple teams with the same name exist, delete duplicates in Teams admin center

### SharePoint site not ready

**Symptom**: `[WAIT] Site not ready -- it may take a few minutes.`

**Cause**: M365 group SPO site takes 30-60s to provision after team creation.

**Fix**: Re-run Step 4a — the team already exists (`[EXISTS]`) and the site will be resolved on the retry.

### Teams posts fail with 403

**Symptom**: `[TEAMS] Post failed: 403 (Forbidden)` in runbook output

**Cause**: The agent's ROPC token doesn't carry `ChannelMessage.Send` permission, or admin consent is missing.

**Fix**:
1. Verify admin consent includes `ChannelMessage.Send`: check `oauth2PermissionGrants` on the service principal
2. Re-run `modules/Register-AgentApp.ps1` to re-create the app with all scopes
3. The `AgentTeamsChannels` AA variable must be populated (Step 4a does this automatically)

## Step 4b: Sensitivity Labels Issues

### Connect-IPPSSession hangs or fails

**Symptom**: The wizard hangs at "Connecting to Security & Compliance PowerShell..." or shows `[MANUAL]`

**Cause**: `Connect-IPPSSession` requires interactive browser authentication. On MCAPS/ME tenants, this may open a browser popup.

**Fix (recommended)**: Pre-connect IPPS before running the wizard:
```powershell
Connect-IPPSSession
# Authenticate in the browser popup
# Then run the wizard — it will detect the existing session automatically
.\Install-AutonomousAgents.ps1 -SkipPrerequisites
```

**v2.1 behavior**: `Configure-DLP.ps1` now detects existing IPPS sessions via `Get-DlpCompliancePolicy`. If a session is already active, it shows `[OK] (existing session)` instantly instead of trying to reconnect.

### Labels already exist with different names

**Symptom**: `[SKIP]` for labels that exist but have different display names than expected

**Cause**: Your tenant already has sensitivity labels with different naming conventions.

**Fix**: Use `-SkipPublish` flag and map your existing labels in the runbook's `$labelRules` hashtable (line ~56 of `Invoke-AgentRunbook.ps1`).

## Step 4c: Fabric Provisioning Issues

### F2 capacity creation fails

**Symptom**: `[FAIL] Fabric F2 may not be available in <region>`

**Cause**: Fabric F2 is not available in all Azure regions.

**Fix**: Change `location` in `agents.json` to a supported region (e.g., `eastus2`, `westeurope`, `francecentral`), or use existing mode `[E]` and provide an existing workspace/lakehouse ID.

### OneLake uploads fail silently

**Symptom**: Runbook output shows `[WARN] OneLake upload failed` for Emma Leroy

**Cause**: F2 capacity is paused, or workspace/lakehouse IDs are incorrect.

**Fix**:
```powershell
# Resume F2 capacity
az resource invoke-action --action resume --resource-type "Microsoft.Fabric/capacities" `
    --name fabriclabcap --resource-group <RG>
# Verify AA variables
az automation variable show --automation-account-name <AA> -g <RG> -n AgentFabricWorkspaceId
```
