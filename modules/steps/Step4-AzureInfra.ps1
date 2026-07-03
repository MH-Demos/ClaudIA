# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# Abort contract: set $script:AAInstallAborted = $true then return to stop
# the whole install (a bare return only exits this file).
# =============================================================================
# ============================================================================
# STEP 4: DEPLOY AZURE INFRASTRUCTURE
# ============================================================================
if (Test-AAInstallStep '4') {
    Write-Host "=== Step 4: Deploying Azure infrastructure ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        # Pre-flight: verify globally-unique resource names are still available worldwide
        # before any resource is created. Avoids partial deployments that leave billable
        # Automation Account / OpenAI resources orphaned after a mid-run collision.
        # In -Auto mode we also pass -AutoFix so the wizard rewrites colliding names
        # to alternative deterministic candidates and reloads agents.json in-place.
        Write-Host "  Pre-flight: checking globally-unique resource name availability..." -ForegroundColor Cyan
        Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 30)
        $preflightArgs = @{ ConfigPath = $ConfigPath; InstallationDefinitionsPath = $installationDefinitionsPath }
        if ($Auto -or $UseInstallationDefinitions) { $preflightArgs['AutoFix'] = $true }
        & (Join-Path $installRoot 'tools\Test-NameAvailability.ps1') @preflightArgs | Out-Host
        $preflightExit = $LASTEXITCODE
        if ($preflightExit -eq 0 -and ($Auto -or $UseInstallationDefinitions)) {
            # Reload config in case AutoFix renamed any field on disk.
            $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        }
        if ($preflightExit -eq 1) {
            Write-Host ""
            Write-Host "  [BLOCKED] At least one resource name is still taken globally after auto-fix attempts." -ForegroundColor Red
            Write-Host "            Step 4 aborted before creating any Azure resource." -ForegroundColor Red
            Write-Host "            Try a different infrastructure.resourceGroup or tenant.subscriptionId, or edit config/agents.json manually, then re-run:" -ForegroundColor Yellow
            Write-Host "              .\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites" -ForegroundColor Cyan
            Stop-Transcript | Out-Null
            $script:AAInstallAborted = $true; return
        } elseif ($preflightExit -eq 2) {
            Write-Host "  [WARN] Some name-availability checks could not complete (not signed in to az?). Continuing." -ForegroundColor Yellow
        }

        $step4Auto = [bool]($Auto -or $UseInstallationDefinitions)
        & (Join-Path $installRoot 'modules\Deploy-AzureInfra.ps1') -Config $config -Auto:$step4Auto
        if ($config.adx -and $config.adx.enabled -eq $true) {
            & (Join-Path $installRoot 'tools\Deploy-AdxTelemetry.ps1') -InstallationDefinitionsPath $installationDefinitionsPath
            $savedAfterAdx = Get-Content $installationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($savedAfterAdx.adx) {
                if ($config.PSObject.Properties['adx']) { $config.adx = $savedAfterAdx.adx }
                else { $config | Add-Member -NotePropertyName adx -NotePropertyValue $savedAfterAdx.adx -Force }
            }
        }
        Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 30)
        Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
            -RunLogPath $runLogPath -RunStamp $runStamp
        if (-not (Test-AAAutomationAccountAvailable -Config $config)) {
            Write-Host ""
            Write-Host "  [ERROR] Step 4 did not leave Automation Account '$($config.infrastructure.automationAccountName)' available." -ForegroundColor Red
            Write-Host "          Step 4a cannot create SharePoint/Teams collaboration assets because it stores IDs in Automation variables." -ForegroundColor Yellow
            Write-Host "          Review the Step 4 error above, then rerun: .\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites" -ForegroundColor Yellow
            $script:AAInstallAborted = $true; return
        }
    } else {
        Write-Host "  [DRY-RUN] Would create: Azure OpenAI, Automation Account, Key Vault access, and ADX telemetry" -ForegroundColor DarkYellow
    }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4' -Value ([ordered]@{
        activity = 'Azure infrastructure and Key Vault'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        resourceGroup = $config.infrastructure.resourceGroup
        automationAccountName = $config.infrastructure.automationAccountName
        openAiAccountName = $config.infrastructure.openAiAccountName
        openAiModel = $config.infrastructure.openAiModel
        openAiModelVersion = $config.infrastructure.openAiModelVersion
        openAiImageModel = $config.infrastructure.openAiImageModel
        openAiImageModelVersion = $config.infrastructure.openAiImageModelVersion
        adx = $config.adx
        keyVaultName = Get-KeyVaultName -Config $config
        fabricEnabled = $config.infrastructure.fabricEnabled
    })
    Write-Host ""
}

