# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 9: BROWSERAGENT CLOUD AUTOMATION (optional)
# ============================================================================
if (Test-AAInstallStep '9') {
    Write-Host "=== Step 9: BrowserAgent Cloud Automation ===" -ForegroundColor Cyan
    Write-Host "  Creates regional Azure Playwright Workspaces and scheduled Container Apps Jobs." -ForegroundColor Gray
    Write-Host "  This is optional and requires BrowserAgents auth state under BrowserAgents\\.auth." -ForegroundColor Gray
    Write-Host ""

    $deployBrowserAgents = 'n'
    $browserAgentJobsStatus = 'not-requested'
    $browserAgentJobsComment = ''
    if (-not $DryRun) {
        $deployBrowserAgents = if ($Auto) { 'n' } else { Read-Host "  Deploy BrowserAgent cloud automation now? (y/N)" }
        if ($deployBrowserAgents -in @('y','Y','yes','YES')) {
            Sync-AABrowserAgentConfig -Config $config
            $authDir = Join-Path $installRoot 'BrowserAgents\.auth'
            $authFiles = @(Get-ChildItem -LiteralPath $authDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
            $configuredAgentCount = @($config.agents | Where-Object { $_.sam }).Count
            if ($authFiles.Count -lt $configuredAgentCount) {
                Write-Host "  BrowserAgent session states: $($authFiles.Count)/$configuredAgentCount found." -ForegroundColor DarkYellow
                Write-Host "  Scheduled jobs package BrowserAgents\\.auth into a private container image." -ForegroundColor Gray
                Write-Host "  Base initialization validates Office and OWA; Teams can be validated later because first-run provisioning can be slow." -ForegroundColor Gray
                $initBrowserAgents = if ($Auto) { 'n' } else { Read-Host "  Initialize BrowserAgent sessions now before continuing? (Y/n)" }
                if ($initBrowserAgents -notin @('n','N','no','NO')) {
                    & (Join-Path $installRoot 'tools\Initialize-BrowserAgents.ps1') `
                        -All `
                        -Services office,owa `
                        -ContinueOnFailure `
                        -ConfigPath $ConfigPath
                    $authFiles = @(Get-ChildItem -LiteralPath $authDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
                    Write-Host "  BrowserAgent session states after initialization: $($authFiles.Count)/$configuredAgentCount found." -ForegroundColor Gray
                }
            }

            $workspaceResults = @()
            $regionalWorkspaces = @($config.browserAgents.regionalWorkspaces)
            if ($regionalWorkspaces.Count -eq 0) { $regionalWorkspaces = @($config.browserAgents) }

            foreach ($workspaceConfig in $regionalWorkspaces) {
                $key = if ($workspaceConfig.key) { [string]$workspaceConfig.key } else { 'americas' }
                $location = if ($workspaceConfig.location) { [string]$workspaceConfig.location } else { [string]$config.browserAgents.location }
                $workspaceName = if ($workspaceConfig.workspaceName) { [string]$workspaceConfig.workspaceName } else { [string]$config.browserAgents.workspaceName }
                Write-Host ""
                Write-Host "  Deploying Playwright workspace '$key' ($workspaceName / $location)..." -ForegroundColor Cyan
                $result = & (Join-Path $installRoot 'tools\Deploy-BrowserAgentInfra.ps1') `
                    -ConfigPath $ConfigPath `
                    -SubscriptionId $config.tenant.subscriptionId `
                    -ResourceGroup $config.infrastructure.resourceGroup `
                    -Location $location `
                    -WorkspaceName $workspaceName
                $resultObject = @($result | Where-Object { $_.PSObject.Properties['WorkspaceId'] } | Select-Object -Last 1)
                if ($resultObject) {
                    Set-AABrowserWorkspaceResult -Config $config -WorkspaceConfig $workspaceConfig -Result $resultObject
                    $workspaceResults += $resultObject
                }
            }

            Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 30)

            $deployJobs = if ($Auto) { 'n' } else { Read-Host "  Deploy scheduled Container Apps Jobs for BrowserAgents? Requires .auth files. (y/N)" }
            if ($deployJobs -in @('y','Y','yes','YES')) {
                $authFiles = @(Get-ChildItem -LiteralPath $authDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
                if ($authFiles.Count -eq 0) {
                    $browserAgentJobsStatus = 'skipped-missing-auth'
                    $browserAgentJobsComment = 'Playwright Workspaces were deployed, but Container Apps Jobs were skipped because BrowserAgents\.auth has no session files.'
                    Write-Host "  [SKIP] BrowserAgent scheduled jobs were not deployed because no .auth session files exist yet." -ForegroundColor DarkYellow
                    Write-Host "         Capture persona browser sessions first:" -ForegroundColor DarkYellow
                    Write-Host "           .\tools\Initialize-BrowserAgents.ps1 -All -Services office,owa -ContinueOnFailure" -ForegroundColor DarkYellow
                    Write-Host "         Then rerun Step 9 or tools\Deploy-BrowserAgentScheduledJobs.ps1." -ForegroundColor DarkYellow
                } else {
                    foreach ($workspaceConfig in @($config.browserAgents.regionalWorkspaces)) {
                        $key = [string]$workspaceConfig.key
                        $prefix = switch ($key) {
                            'europe' { 'browseragents-eu' }
                            'asia' { 'browseragents-asia' }
                            default { 'browseragents' }
                        }
                        & (Join-Path $installRoot 'tools\Deploy-BrowserAgentScheduledJobs.ps1') `
                            -ConfigPath $ConfigPath `
                            -BrowserRegionKey $key `
                            -JobNamePrefix $prefix `
                            -SkipAgentsMissingAuth `
                            -Deploy
                    }
                    $browserAgentJobsStatus = 'deployed'
                    $browserAgentJobsComment = 'Regional Playwright Workspaces and Container Apps Jobs were deployed.'
                }
            } else {
                $browserAgentJobsStatus = 'skipped-by-user'
                $browserAgentJobsComment = 'Playwright Workspaces were deployed, but Container Apps Jobs were skipped by prompt.'
                Write-Host "  [SKIP] BrowserAgent scheduled jobs skipped. You can run tools\\Deploy-BrowserAgentScheduledJobs.ps1 later." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  [SKIP] BrowserAgent cloud automation skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would deploy regional Playwright Workspaces and optional Container Apps Jobs." -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '9' -Value ([ordered]@{
        activity = 'BrowserAgent cloud automation'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = ($deployBrowserAgents -in @('y','Y','yes','YES'))
        jobsStatus = $browserAgentJobsStatus
        regionalWorkspaces = $config.browserAgents.regionalWorkspaces
    })
    if ($deployBrowserAgents -in @('y','Y','yes','YES')) {
        $step9Status = if ($browserAgentJobsStatus -eq 'deployed') { 'deployed' } elseif ($DryRun) { 'skipped' } else { 'partial' }
        $step9Comment = if ($browserAgentJobsComment) { $browserAgentJobsComment } else { 'Completed in this run. Review module output above for detailed actions.' }
        Set-AADeploymentResult -Step '9' -MainActivity 'BrowserAgent cloud automation' -Status $step9Status -Comments $step9Comment
    }
    Write-Host ""
}

