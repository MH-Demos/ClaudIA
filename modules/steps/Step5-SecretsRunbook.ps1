# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 5: STORE SECRETS + DEPLOY RUNBOOK
# ============================================================================
if (Test-AAInstallStep '5') {
    Write-Host "=== Step 5: Storing secrets + deploying runbook ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        # Password may already be set from Step 1 (new users or auto-reset)
        if (-not $agentPassword -and $installBoundParams.ContainsKey('AgentPassword')) {
            $agentPassword = $installBoundParams['AgentPassword']
        }
        if (-not $agentPassword) {
            Write-Host "  No -AgentPassword provided. Existing per-agent Key Vault secrets will be preserved." -ForegroundColor Cyan
            Write-Host "  Provide -AgentPassword only when intentionally writing one shared password to every agent secret." -ForegroundColor Gray
        }
        $oldM365ConfigDir = $env:CLAUDIA_M365_AZURE_CONFIG_DIR
        if ($script:AAM365AzConfigDir) { $env:CLAUDIA_M365_AZURE_CONFIG_DIR = $script:AAM365AzConfigDir }
        try {
            & (Join-Path $installRoot 'modules\Deploy-Runbook.ps1') -Config $config -AgentPassword $agentPassword
        } finally {
            if ($null -ne $oldM365ConfigDir) { $env:CLAUDIA_M365_AZURE_CONFIG_DIR = $oldM365ConfigDir }
            else { Remove-Item Env:\CLAUDIA_M365_AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Host "  [DRY-RUN] Would preserve/write Key Vault secrets, update Automation variables, and publish runbook" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '5' -Value ([ordered]@{
        activity = 'Key Vault secrets and runbook'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        keyVaultName = Get-KeyVaultName -Config $config
        clientSecretName = 'agent-client-secret'
        agentSecretNames = @($agents | ForEach-Object {
            [ordered]@{
                upn = Get-AgentUpn -Agent $_ -Domain $domain
                secretName = Get-AgentSecretName -Agent $_ -Domain $domain
            }
        })
        runbookName = 'Invoke-AgentRunbook'
        schedules = $config.schedules
    })
    Write-Host ""
}

