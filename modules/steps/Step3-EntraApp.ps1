# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# Abort contract: set $script:AAInstallAborted = $true then return to stop
# the whole install (a bare return only exits this file).
# =============================================================================
# ============================================================================
# STEP 3: REGISTER ENTRA APP
# ============================================================================
if (Test-AAInstallStep '3') {
    Write-Host "=== Step 3: Registering Entra app (app-claudia-dataagent) ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        if ($script:AAM365AzConfigDir) {
            $oldConfigDir = $env:AZURE_CONFIG_DIR
            $env:AZURE_CONFIG_DIR = $script:AAM365AzConfigDir
            try {
                & (Join-Path $installRoot 'modules\Register-AgentApp.ps1') -Domain $domain
            } finally {
                if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
                else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
            }
        } else {
            & (Join-Path $installRoot 'modules\Register-AgentApp.ps1') -Domain $domain
        }
    } else {
        Write-Host "  [DRY-RUN] Would register app with delegated scopes for ROPC" -ForegroundColor DarkYellow
    }
    $appDataAgentId = if (-not $DryRun) {
        if ($script:AAM365AzConfigDir) {
            Invoke-AAM365Az -Arguments @('ad','app','list','--display-name','app-claudia-dataagent','--query','[0].appId','-o','tsv') 2>$null
        } else {
            az ad app list --display-name 'app-claudia-dataagent' --query "[0].appId" -o tsv 2>$null
        }
    } else { $null }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '3' -Value ([ordered]@{
        activity = 'Register app-claudia-dataagent'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        appName = 'app-claudia-dataagent'
        appId = $appDataAgentId
    })
    Write-Host ""
}

