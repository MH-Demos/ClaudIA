# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# Abort contract: set $script:AAInstallAborted = $true then return to stop
# the whole install (a bare return only exits this file).
# =============================================================================
# ============================================================================
# STEP 2: ASSIGN LICENSES + MFA EXCLUSION
# ============================================================================
if (Test-AAInstallStep '2') {
    Write-Host "=== Step 2: Assigning licenses + MFA exclusion ===" -ForegroundColor Cyan

    if (-not $DryRun) {
        $gt = Get-AAGraphAccessToken
        $gh = @{Authorization="Bearer $gt"; 'Content-Type'='application/json'}
        $copilotAgents = @($agents | Where-Object { $_.copilotLicense -eq $true })
        $copilotAssignedCount = 0
        $copilotSkippedCount = 0

        # Find best available license SKU (E3, E5, E7, or equivalent)
        $skus = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/subscribedSkus" -Headers $gh).value
        $eligible = $skus | Where-Object { $_.skuPartNumber -match 'E[357]|SPE_|ENTERPRISEP|EMSPREMIUM|M365_' }
        $copilotSku = $skus | Where-Object { $_.skuPartNumber -match 'Copilot' }

        if ($eligible) {
            $bestSku = $eligible | Sort-Object { $_.prepaidUnits.enabled } -Descending | Select-Object -First 1
            $availLic = $bestSku.prepaidUnits.enabled - $bestSku.consumedUnits
            Write-Host "  Found license: $($bestSku.skuPartNumber) ($availLic available)" -ForegroundColor Cyan

            if ($availLic -le 0) {
                Write-Host "  [WARN] No available licenses to assign. Agents will rely on tenant-wide service enablement." -ForegroundColor Yellow
                Write-Host "         If ROPC fails later, assign licenses manually or increase license count." -ForegroundColor Yellow
            }

            foreach ($agent in $agents) {
                $upn = Get-AgentUpn -Agent $agent -Domain $domain
                # Graph API may not find newly created users immediately (Entra replication delay)
                $userId = $null
                try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
                if (-not $userId) {
                    Write-Host "  [WAIT] $upn not yet replicated -- retrying in 5s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 5
                    try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
                }
                if (-not $userId) { Write-Host "  [SKIP] $upn not found (replication delay)" -ForegroundColor DarkYellow; continue }

                # Try to assign license (will fail gracefully if no seats available)
                if ($availLic -gt 0) {
                    $licBody = @{addLicenses=@(@{skuId=$bestSku.skuId}); removeLicenses=@()} | ConvertTo-Json -Depth 3
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$userId/assignLicense" `
                            -Headers $gh -Body $licBody | Out-Null
                        Write-Host "  $($agent.displayName): $($bestSku.skuPartNumber)" -NoNewline -ForegroundColor Green
                        $availLic--
                    } catch {
                        $licenseError = $_.Exception.Message
                        Write-Host "  $($agent.displayName): license assign failed ($licenseError)" -NoNewline -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "  $($agent.displayName): no seats left (tenant-wide)" -NoNewline -ForegroundColor DarkYellow
                }

                # Assign Copilot if needed
                if ($agent.copilotLicense -and $copilotSku) {
                    $copBody = @{addLicenses=@(@{skuId=$copilotSku[0].skuId}); removeLicenses=@()} | ConvertTo-Json -Depth 3
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$userId/assignLicense" `
                            -Headers $gh -Body $copBody | Out-Null
                        Write-Host " + Copilot" -ForegroundColor Green
                        $copilotAssignedCount++
                    } catch { Write-Host " + Copilot skipped" -ForegroundColor DarkYellow }
                } elseif ($agent.copilotLicense) {
                    $copilotSkippedCount++
                    Write-Host " + Copilot unavailable" -ForegroundColor DarkYellow
                } else {
                    Write-Host "" # newline
                }
            }
        } else {
            Write-Host "  [WARN] No E3/E5/E7 licenses found in tenant." -ForegroundColor Yellow
            Write-Host "         Agents will rely on tenant-wide service enablement." -ForegroundColor Yellow
            Write-Host "         If ROPC/Graph fails later, assign licenses manually." -ForegroundColor Yellow
        }

        if ($copilotAgents.Count -gt 0 -and $copilotAssignedCount -eq 0) {
            Write-Host ""
            Write-Host "  [WARN] No Microsoft 365 Copilot licenses were assigned to the $($copilotAgents.Count) configured Copilot agent(s)." -ForegroundColor Yellow
            Write-Host "         ClaudIA can disable Copilot-specific tasks for now." -ForegroundColor Yellow
            Write-Host "         Non-Copilot AI emulation, including ExternalAI scenarios through Azure AI Foundry, can remain enabled." -ForegroundColor Gray
            $disableCopilot = if ($Auto) { 'Y' } else { Read-Host "  Disable Copilot-specific runbook tasks until Copilot licenses are available? (Y/n)" }
            if ($disableCopilot -notin @('n','N','no','NO')) {
                Set-AACopilotQueriesFeature -Config $config -Enabled:$false
                $configChanged = $true
                Save-AAJsonAtomic -Path $ConfigPath -Json ($config | ConvertTo-Json -Depth 20)
                Write-Host "  [OK] features.copilotQueries set to false. Use tools\\Set-CopilotTasks.ps1 -Mode Enable after assigning Copilot licenses." -ForegroundColor Green
            }
        }

        # Create/reuse MFA exclusion group
        Write-Host "  Resolving MFA exclusion group..." -NoNewline
        $grpBody = @{displayName='grp-claudia-agent-mfa-exclusion'; description='ClaudIA agents excluded from MFA for ROPC'; mailEnabled=$false; mailNickname='grp-claudia-mfa'; securityEnabled=$true} | ConvertTo-Json
        $savedMfaGroupId = $null
        if ($savedDefinitions -and $savedDefinitions.steps -and $savedDefinitions.steps.'2' -and $savedDefinitions.steps.'2'.mfaExclusionGroupId) {
            $savedMfaGroupId = $savedDefinitions.steps.'2'.mfaExclusionGroupId
        }
        $grp = $null
        if ($savedMfaGroupId) {
            try {
                $grp = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$savedMfaGroupId" -Headers $gh -ErrorAction Stop
                Write-Host " [EXISTS] $($grp.id)" -ForegroundColor DarkYellow
            } catch {
                Write-Host " [STALE ID]" -ForegroundColor DarkYellow
                Write-Host "  Saved group id '$savedMfaGroupId' was not found; searching by name..." -ForegroundColor DarkYellow
            }
        }
        if (-not $grp) {
            $existingGroups = @((Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq 'grp-claudia-agent-mfa-exclusion'&`$select=id,displayName" -Headers $gh).value)
            if ($existingGroups.Count -gt 0) {
                $grp = $existingGroups[0]
                Write-Host " [EXISTS] $($grp.id)" -ForegroundColor DarkYellow
            } else {
                $grp = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups" -Headers $gh -Body $grpBody
                Write-Host " [OK] $($grp.id)" -ForegroundColor Green
            }
        }

        # Add agents to group
        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            $userId = $null
            try { $userId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/users/$upn" -Headers $gh).id } catch {}
            if ($userId) {
                try {
                    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)/members/`$ref" `
                        -Headers $gh -Body (@{'@odata.id'="https://graph.microsoft.com/v1.0/directoryObjects/$userId"} | ConvertTo-Json) | Out-Null
                } catch {} # already member
            }
        }
        Write-Host "  All agents added to MFA exclusion group." -ForegroundColor Green
    } else {
        Write-Host "  [DRY-RUN] Would assign E5 + Copilot licenses and create MFA exclusion group" -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '2' -Value ([ordered]@{
        activity = 'Licenses and MFA exclusion'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        mfaExclusionGroup = 'grp-claudia-agent-mfa-exclusion'
        mfaExclusionGroupId = if ($grp) { $grp.id } else { $null }
        selectedLicenseSku = if ($bestSku) { $bestSku.skuPartNumber } else { $null }
        copilotSku = if ($copilotSku) { $copilotSku[0].skuPartNumber } else { $null }
        agentUpns = @($agents | ForEach-Object { Get-AgentUpn -Agent $_ -Domain $domain })
    })

    Write-Host ""
    Write-Host "  MANUAL STEP REQUIRED:" -ForegroundColor Yellow
    Write-Host "    1. Go to Entra admin center > Conditional Access" -ForegroundColor Yellow
    Write-Host "    2. Edit your MFA policy > Exclude > Groups > Add 'grp-claudia-agent-mfa-exclusion'" -ForegroundColor Yellow
    Write-Host "    3. Save the policy" -ForegroundColor Yellow
    Write-Host ""
    if (-not $Auto -and -not $DryRun) {
        Read-Host "  Press Enter when done (or skip if CA is not enforced)"
    } elseif ($Auto) {
        Write-Host "  [AUTO] Skipping MFA manual step -- ensure CA exclusion is configured" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

