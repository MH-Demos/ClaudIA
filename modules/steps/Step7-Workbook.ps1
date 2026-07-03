# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 7: DEPLOY WORKBOOK (optional)
# ============================================================================
if (Test-AAInstallStep '7') {
    Write-Host "=== Step 7: ClaudIA Activity Monitor Workbook ===" -ForegroundColor Cyan
    Write-Host "  Deploys Azure Monitor workbook backed by ADX telemetry. Optional." -ForegroundColor Gray

    $deployWb = 'y'
    if (-not $DryRun) {
        $deployWb = if ($Auto) { 'y' } else { Read-Host "  Deploy workbook? (Y/n)" }
        if ($deployWb -ne 'n') {
            & (Join-Path $installRoot 'modules\Deploy-Workbook.ps1') -Config $config
        } else {
            Write-Host "  [SKIP] Workbook skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would deploy Azure Monitor workbook with KQL queries" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '7' -Value ([ordered]@{
        activity = 'ClaudIA Activity Monitor workbook'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployWb) { $deployWb -ne 'n' } else { -not $DryRun }
        workbookName = 'ClaudIA Activity Monitor'
        telemetryBackend = 'ADX'
    })
    Write-Host ""
}

