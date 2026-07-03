# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 6a: CORE DLP POLICIES (optional - 6 workload policies)
# ============================================================================
if (Test-AAInstallStep '6a') {
    Write-Host "=== Step 6a: Core DLP Policies (6 workload policies) ===" -ForegroundColor Cyan
    Write-Host "  Deploys category-based DLP policies: Exchange, SharePoint, OneDrive, Teams, Endpoint, Copilot." -ForegroundColor Gray
    Write-Host "  All in AUDIT mode (TestWithNotifications). Optional but recommended." -ForegroundColor Gray

    $deployCoreDlp = 'y'
    if (-not $DryRun) {
        $deployCoreDlp = if ($Auto) { 'y' } else { Read-Host "  Deploy core DLP policies? (Y/n)" }
        if ($deployCoreDlp -ne 'n') {
            & (Join-Path $installRoot 'modules\Configure-CoreDLP.ps1') -Config $config -Domain $domain
        } else {
            Write-Host "  [SKIP] Core DLP policies skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would create 6 workload DLP policies with category-based rules" -ForegroundColor DarkYellow
    }
    $coreDlpPolicySuffix = if ([string]::IsNullOrWhiteSpace($domain)) { 'TENANT' } else { (($domain -split '\.')[0]).ToUpperInvariant() }
    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '6a' -Value ([ordered]@{
        activity = 'Core DLP policies'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = if ($deployCoreDlp) { $deployCoreDlp -ne 'n' } else { -not $DryRun }
        policies = @(
            "EXO Policy - $coreDlpPolicySuffix",
            "SPO Policy - $coreDlpPolicySuffix",
            "ODB Policy - $coreDlpPolicySuffix",
            "Teams Policy - $coreDlpPolicySuffix",
            "Endpoint Policy - $coreDlpPolicySuffix",
            "Copilot Policy - $coreDlpPolicySuffix"
        )
    })
    Write-Host ""
}

