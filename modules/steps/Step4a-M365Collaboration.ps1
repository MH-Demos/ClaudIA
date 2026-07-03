# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 4a: M365 COLLABORATION (SharePoint + Teams)
# ============================================================================
if (Test-AAInstallStep '4a') {
    Write-Host "=== Step 4a: M365 Collaboration (SharePoint + Teams) ===" -ForegroundColor Cyan
    Write-Host "  Creates SharePoint site + Teams team + department channels." -ForegroundColor Gray
    Write-Host "  Agents upload files and post activity here." -ForegroundColor Gray
    Write-Host ""

    $step4aBlocked = $false
    if (-not $DryRun) {
        if (-not (Test-AAAutomationAccountAvailable -Config $config)) {
            Write-Host "  [ERROR] Automation Account '$($config.infrastructure.automationAccountName)' was not found." -ForegroundColor Red
            Write-Host "          Step 4a needs the Automation Account from Step 4 to store Teams and SharePoint IDs as Automation variables." -ForegroundColor Yellow
            Write-Host "          Run Step 4 first and confirm Azure infrastructure completes successfully:" -ForegroundColor Yellow
            Write-Host "          .\Install-ClaudIA.ps1 -Step 4 -SkipPrerequisites" -ForegroundColor Cyan
            Write-Host ""
            Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4a' -Value ([ordered]@{
                activity = 'M365 collaboration'
                completedAt = (Get-Date).ToString('o')
                status = 'blocked'
                reason = 'Automation Account missing. Step 4 must complete before Step 4a.'
            })
            # Skip 4a only: 4b (labels) and 4c (Fabric) do not depend on the
            # Automation Account, so aborting the whole run here lost their work.
            $step4aBlocked = $true
        }
        if (-not $step4aBlocked) {
            Write-Host "    [C] Create new site + team (default)" -ForegroundColor Gray
            Write-Host "    [E] Use existing resources (enter IDs)" -ForegroundColor Gray
            $m365Mode = if ($Auto) { 'C' } else { Read-Host "    Choice (C/E)" }
            $m365ModeStr = if ($m365Mode -eq 'E') { 'existing' } else { 'create' }
            $oldGraphToken = $env:CLAUDIA_GRAPH_TOKEN
            if ($script:AAM365AzConfigDir) { $env:CLAUDIA_GRAPH_TOKEN = Get-AAGraphAccessToken }
            try {
                & (Join-Path $installRoot 'modules\Provision-M365Collaboration.ps1') -Config $config -Mode $m365ModeStr
            } finally {
                if ($null -ne $oldGraphToken) { $env:CLAUDIA_GRAPH_TOKEN = $oldGraphToken }
                else { Remove-Item Env:\CLAUDIA_GRAPH_TOKEN -ErrorAction SilentlyContinue }
            }
        }
    } else {
        Write-Host "  [DRY-RUN] Would provision SharePoint site + Teams team" -ForegroundColor DarkYellow
    }
    if (-not $step4aBlocked) {
        Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '4a' -Value ([ordered]@{
            activity = 'M365 collaboration'
            completedAt = (Get-Date).ToString('o')
            dryRun = [bool]$DryRun
            mode = if ($m365ModeStr) { $m365ModeStr } else { 'dry-run' }
            teamName = 'CorpLab - Departments'
            departments = @('HR', 'Finance', 'Legal', 'Engineering', 'Sales')
            agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
        })
    }
    Write-Host ""
}

