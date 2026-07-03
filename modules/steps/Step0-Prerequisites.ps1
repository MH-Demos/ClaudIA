# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# Abort contract: set $script:AAInstallAborted = $true then return to stop
# the whole install (a bare return only exits this file).
# =============================================================================
# ============================================================================
# STEP 0: PREREQUISITES
# ============================================================================
if ((Test-AAInstallStep '0') -and -not $SkipPrerequisites) {
    Write-Host "=== Step 0: Checking prerequisites ===" -ForegroundColor Cyan
    if (-not $script:AAM365AzConfigDir) {
        Initialize-AAM365AdminProfileFromDisk | Out-Null
    }
    $prereqParams = @{
        ConfigPath = $ConfigPath
    }
    if ($RegisterProviders) { $prereqParams.RegisterProviders = $true }
    if ($script:AAM365AzConfigDir) { $prereqParams.M365AzureConfigDir = $script:AAM365AzConfigDir }
    $prereq = & (Join-Path $installRoot 'prerequisites\Test-Prerequisites.ps1') @prereqParams
    if (-not $prereq.AllPassed) {
        Show-AAPrerequisiteGuidance -PrerequisiteResult $prereq

        if (-not $RegisterProviders -and (Test-AAOnlyProviderFailures -PrerequisiteResult $prereq)) {
            Write-Host ""
            Write-Host "  The only failed checks are Azure resource providers." -ForegroundColor Yellow
            Write-Host "  ClaudIA can register them now. This may take several minutes in a new subscription." -ForegroundColor Gray
            $registerNow = if ($Auto) { 'Y' } else { Read-Host "  Register missing Azure resource providers now and rerun prerequisites? (Y/n)" }
            if ($registerNow -notin @('n','N','no','NO')) {
                $prereqParams.RegisterProviders = $true
                $prereq = & (Join-Path $installRoot 'prerequisites\Test-Prerequisites.ps1') @prereqParams
                if ($prereq.AllPassed) {
                    Write-Host ""
                    Write-Host "  [OK] Azure resource providers are registered. Continuing deployment." -ForegroundColor Green
                } else {
                    Show-AAPrerequisiteGuidance -PrerequisiteResult $prereq
                }
            }
        }

        $adminRoleFailure = @($prereq.Results | Where-Object {
            $_.Status -eq 'Fail' -and $_.Name -eq 'Deploying user has admin directory role'
        })
        if ($adminRoleFailure.Count -gt 0 -and -not $Auto) {
            Write-Host ""
            if ($script:AAM365AzConfigDir) {
                Write-Host "  The saved Microsoft 365 admin profile did not satisfy the admin role check." -ForegroundColor Yellow
            } else {
                Write-Host "  ClaudIA can use a separate Microsoft 365/Entra admin sign-in for tenant setup while keeping the current Azure subscription sign-in." -ForegroundColor Yellow
            }
            $m365SignIn = Read-Host "  Sign in with a separate Microsoft 365/Entra admin account and rerun prerequisites? (Y/n)"
            if ($m365SignIn -notin @('n','N','no','NO')) {
                if (Initialize-AAM365AdminSignIn -TenantHint $config.tenant.domain) {
                    $prereqParams.M365AzureConfigDir = $script:AAM365AzConfigDir
                    $prereq = & (Join-Path $installRoot 'prerequisites\Test-Prerequisites.ps1') @prereqParams
                    if ($prereq.AllPassed) {
                        Write-Host ""
                        Write-Host "  [OK] Microsoft 365 admin prerequisites passed. Continuing deployment." -ForegroundColor Green
                    } else {
                        Show-AAPrerequisiteGuidance -PrerequisiteResult $prereq
                    }
                }
            }
        }

        if (-not $prereq.AllPassed) {
            Write-Host ""
            Write-Host "[BLOCKED] Fix prerequisite failures before continuing." -ForegroundColor Red
            $continue = if ($Auto) { 'y' } else { Read-Host "  Continue anyway? (y/N)" }
            if ($continue -ne 'y') { $script:AAInstallAborted = $true; return }
        }
    }
    if ($prereq.AllPassed) {
        Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '0' -Value ([ordered]@{
            activity = 'Reset connections and validate prerequisites'
            completedAt = (Get-Date).ToString('o')
            connectionReset = $script:AAInstallationDefinitions.sessionReset
            prerequisitesAllPassed = $prereq.AllPassed
        })
        Set-AADeploymentResult -Step '0' -MainActivity 'Prerequisite validation' -Status 'deployed' -Comments 'Completed; Copilot availability is warning/pending for existing users.'
        Write-Host ""
    }
} elseif ($SkipPrerequisites) {
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '0' -Value ([ordered]@{
        activity = 'Reset connections and validate prerequisites'
        completedAt = (Get-Date).ToString('o')
        skipped = $true
        reason = 'Skipped by parameter.'
    })
    Set-AADeploymentResult -Step '0' -MainActivity 'Prerequisite validation' -Status 'skipped' -Comments 'Skipped by parameter.'
}

