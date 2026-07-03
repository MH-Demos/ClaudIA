# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 6b: DSPM FOR AI POLICIES (optional - 3 policies)
# ============================================================================
if (Test-AAInstallStep '6b') {
    Write-Host "=== Step 6b: DSPM for AI Policies (3 policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys 3 DSPM DLP policies for AI/Copilot governance." -ForegroundColor Gray

    $deployDspm = 'y'
    if (-not $DryRun) {
        $deployDspm = if ($Auto) { 'y' } else { Read-Host "  Deploy DSPM for AI policies? (Y/n)" }
        if ($deployDspm -ne 'n') {
            & (Join-Path $installRoot 'modules\Configure-DLP.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] DSPM policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 3 DSPM DLP policies + IRM instructions" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6b' -Value ([ordered]@{
        activity = 'DSPM for AI policies'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployDspm) { $deployDspm -ne 'n' } else { -not $DryRun }
        policies = @('DLP-CopilotStudio-PII-Monitor','DSPM-AI-Labels-Restrict','DSPM-AI-ClaudIAActivity-Audit')
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })
    Write-Host ""
}

