# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 6c: INSIDER RISK MANAGEMENT (optional - 2 policies)
# ============================================================================
if (Test-AAInstallStep '6c') {
    Write-Host "=== Step 6c: Insider Risk Management (2 policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys IRM-DataLeaks-Lab (DLP-triggered) + IRM-RiskyAI-Lab." -ForegroundColor Gray
    Write-Host "  Requires core DLP policies from Step 6a. Optional." -ForegroundColor Gray

    $deployIrm = 'y'
    if (-not $DryRun) {
        $deployIrm = if ($Auto) { 'y' } else { Read-Host "  Deploy IRM policies? (Y/n)" }
        if ($deployIrm -ne 'n') {
            & (Join-Path $installRoot 'modules\Configure-IRM.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] IRM policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 2 IRM policies (DataLeaks + RiskyAI)" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6c' -Value ([ordered]@{
        activity = 'Insider Risk Management'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployIrm) { $deployIrm -ne 'n' } else { -not $DryRun }
        policies = @('IRM-DataLeaks-Lab','IRM-RiskyAI-Lab')
        priorityUserGroup = 'ClaudIA Agents'
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })
    Write-Host ""
}

