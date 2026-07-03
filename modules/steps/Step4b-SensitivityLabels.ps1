# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 4b: SENSITIVITY LABELS (optional)
# ============================================================================
if (Test-AAInstallStep '4b') {
    Write-Host "=== Step 4b: Sensitivity Labels ===" -ForegroundColor Cyan
    Write-Host "  Creates General, Confidential, Conf-HR, Conf-Finance, Highly Confidential labels." -ForegroundColor Gray
    Write-Host "  Required for agent file classification. Optional if labels already exist." -ForegroundColor Gray
    Write-Host ""

    if (-not $DryRun) {
        $deployLabels = if ($Auto) { 'y' } else { Read-Host "  Deploy sensitivity labels? (Y/n)" }
        if ($deployLabels -ne 'n') {
            & (Join-Path $installRoot 'modules\Provision-SensitivityLabels.ps1') -Config $config
        } else {
            Write-Host "  [SKIP] Labels skipped. Ensure they exist for file classification." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 5 sensitivity labels + publish policy" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4b' -Value ([ordered]@{
        activity = 'Sensitivity labels'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployLabels) { $deployLabels -ne 'n' } else { -not $DryRun }
        labels = @('General', 'Confidential', 'Conf-HR', 'Conf-Finance', 'Highly Confidential')
        policyName = 'CorpLab-Labels-Policy'
    })
    Write-Host ""
}

