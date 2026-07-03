# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 4c: FABRIC PROVISIONING (conditional)
# ============================================================================
if ((Test-AAInstallStep '4c') -and $config.infrastructure.fabricEnabled) {
    Write-Host "=== Step 4c: Fabric Provisioning ===" -ForegroundColor Cyan
    Write-Host "  Creates Fabric F2 capacity, workspace, and lakehouse for Engineering data." -ForegroundColor Gray
    Write-Host "  Cost: ~`$0.36/hr (~`$260/month if running 24/7)." -ForegroundColor Gray
    Write-Host ""

    if (-not $DryRun) {
        Write-Host "    [C] Create new Fabric resources (default)" -ForegroundColor Gray
        Write-Host "    [E] Use existing workspace + lakehouse (enter IDs)" -ForegroundColor Gray
        $fabMode = if ($Auto) { 'C' } else { Read-Host "    Choice (C/E)" }
        $fabModeStr = if ($fabMode -eq 'E') { 'existing' } else { 'create' }
        & (Join-Path $installRoot 'modules\Provision-Fabric.ps1') -Config $config -Mode $fabModeStr
    } else {
        Write-Host "  [DRY-RUN] Would provision Fabric F2 + workspace + lakehouse" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4c' -Value ([ordered]@{
        activity = 'Fabric provisioning'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        enabled = $true
        mode = if ($fabModeStr) { $fabModeStr } else { 'dry-run' }
    })
    Write-Host ""
} elseif ((Test-AAInstallStep '4c') -and -not $config.infrastructure.fabricEnabled) {
    Write-Host "=== Step 4c: Fabric [DISABLED] ===" -ForegroundColor DarkGray
    Write-Host "  Set fabricEnabled=true in agents.json to enable." -ForegroundColor DarkGray
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4c' -Value ([ordered]@{
        activity = 'Fabric provisioning'
        completedAt = (Get-Date).ToString('o')
        enabled = $false
        reason = 'fabricEnabled=false'
    })
    Write-Host ""
}

