# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 8: DEPLOY ACTIVITY STORY MAP (optional)
# ============================================================================
if (Test-AAInstallStep '8') {
    Write-Host "=== Step 8: Activity Story Map ===" -ForegroundColor Cyan
    Write-Host "  Deploys an Azure Storage static website and Azure Function backed by ADX." -ForegroundColor Gray

    $deployStoryMap = 'y'
    $storyMapResult = $null
    if (-not $DryRun) {
        $deployStoryMap = if ($Auto) { 'y' } else { Read-Host "  Deploy Activity Story Map? (Y/n)" }
        if ($deployStoryMap -ne 'n') {
            $storyMapResult = & (Join-Path $installRoot 'modules\Deploy-ActivityStoryMap.ps1') `
                -Config $config `
                -ConfigPath $ConfigPath `
                -InstallationDefinitionsPath $installationDefinitionsPath
            if ($storyMapResult) {
                Set-AAObjectProperty -Object $config -Name 'activityStoryMap' -Value $storyMapResult
            }
            $deployFrontDoor = if ($Auto) { 'N' } else { Read-Host "  Enable Azure Front Door for the Activity Story Map? (y/N)" }
            if ($deployFrontDoor -in @('y','Y','yes','YES')) {
                & (Join-Path $installRoot 'tools\Enable-ActivityStoryMapFrontDoor.ps1') -ConfigPath $ConfigPath
                $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            }
        } else {
            Write-Host "  [SKIP] Activity Story Map skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would deploy Activity Story Map Storage site + Azure Function API" -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '8' -Value ([ordered]@{
        activity = 'Activity Story Map'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployStoryMap) { $deployStoryMap -ne 'n' } else { -not $DryRun }
        staticWebsiteUrl = if ($storyMapResult) { $storyMapResult.staticWebsiteUrl } else { $null }
        apiBaseUrl = if ($storyMapResult) { $storyMapResult.apiBaseUrl } else { $null }
        functionAppName = if ($storyMapResult) { $storyMapResult.functionAppName } else { $null }
    })
    Write-Host ""
}

