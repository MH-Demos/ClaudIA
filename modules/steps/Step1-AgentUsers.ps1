# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# Abort contract: set $script:AAInstallAborted = $true then return to stop
# the whole install (a bare return only exits this file).
# =============================================================================
# ============================================================================
# STEP 1: CREATE OR SELECT AGENT ACCOUNTS
# ============================================================================
if (Test-AAInstallStep '1') {
    # Determine user mode: config setting, CLI switch, or interactive prompt
    $userMode = $config.features.userMode
    if ($UseExistingUsers) { $userMode = 'existing' }

    if (-not $userMode -or $userMode -eq 'prompt') {
        Write-Host "=== Step 1: Agent Account Setup ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  How do you want to set up agent accounts?" -ForegroundColor White
        Write-Host "    [1] Create new users (default 10 personas from agents.json)" -ForegroundColor Gray
        Write-Host "    [2] Use existing tenant users (interactive picker)" -ForegroundColor Gray
        Write-Host ""
        $modeChoice = if ($Auto) { '1' } else { Read-Host "  Choice (1 or 2)" }
        $userMode = if ($modeChoice -eq '2') { 'existing' } else { 'create' }
    }

    if ($userMode -eq 'existing') {
        Write-Host "=== Step 1: Selecting existing users as agents ===" -ForegroundColor Cyan

        if ($DryRun) {
            Write-Host "  [DRY-RUN] Would launch interactive user picker" -ForegroundColor DarkYellow
            Write-Host "  [DRY-RUN] Selected users would replace agents[] in config" -ForegroundColor DarkYellow
        } elseif ($script:PreselectedExistingUsers) {
            Write-Host "  [OK] Existing users were already selected during Step 0 fresh installation setup." -ForegroundColor Green
        } elseif ($UseInstallationDefinitions -and $config.agents -and @($config.agents).Count -gt 0) {
            $agents = @($config.agents)
            $config | Add-Member -NotePropertyName '_runtimeAgents' -NotePropertyValue $agents -Force
            Write-Host "  [OK] Using $($agents.Count) agents from Installation_definitions.json." -ForegroundColor Green
            Write-Host "       Run tools\\Add-StorylineAgents.ps1 to append storyline expansions without replacing the original cast." -ForegroundColor Gray
        } else {
            if ($script:AAM365AzConfigDir) {
                $oldConfigDir = $env:AZURE_CONFIG_DIR
                $env:AZURE_CONFIG_DIR = $script:AAM365AzConfigDir
                try {
                    $selectedAgents = & (Join-Path $installRoot 'modules\Select-ExistingUsers.ps1') -Domain $domain
                } finally {
                    if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
                    else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
                }
            } else {
                $selectedAgents = & (Join-Path $installRoot 'modules\Select-ExistingUsers.ps1') -Domain $domain
            }
            if (-not $selectedAgents -or $selectedAgents.Count -eq 0) {
                Write-Host "  [ERROR] No users selected. Aborting." -ForegroundColor Red
                $script:AAInstallAborted = $true; return
            }
            # Update config in memory with selected users
            $agents = $selectedAgents
            $config | Add-Member -NotePropertyName '_runtimeAgents' -NotePropertyValue $selectedAgents -Force

            # Save updated agents back to config file
            $configObj = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $configObj.agents = $selectedAgents
            $configObj.features.userMode = 'existing'
            Save-AAJsonAtomic -Path $ConfigPath -Json ($configObj | ConvertTo-Json -Depth 5)
            $config = $configObj
            Initialize-AAInstallationDefinitions -Path $installationDefinitionsPath -Config $config -ConfigPath $ConfigPath `
                -RunLogPath $runLogPath -RunStamp $runStamp
            Set-AAInstallationDefinition -Path $installationDefinitionsPath -Section 'selectedUsers' -Value @($selectedAgents | ForEach-Object {
                [ordered]@{
                    sam = $_.sam
                    userPrincipalName = $_.userPrincipalName
                    displayName = $_.displayName
                    department = $_.department
                    jobTitle = $_.jobTitle
                    wave = $_.wave
                    workload = $_.workload
                    keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $domain
                }
            })
            Write-Host "  Updated $ConfigPath with $($selectedAgents.Count) selected users." -ForegroundColor Green
        }

        $w1Count = @($agents | Where-Object { $_.wave -eq 1 }).Count
        $w2Count = @($agents | Where-Object { $_.wave -eq 2 }).Count
        if (-not $DryRun) {
            Write-Host ""
            Write-Host "  ROPC requires a valid password for each selected existing user." -ForegroundColor Yellow
            if ($installBoundParams.ContainsKey('AgentPassword')) {
                $agentPassword = $installBoundParams['AgentPassword']
                $resetExistingChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset selected users to -AgentPassword now? (Y/n)" }
            } else {
                $resetExistingChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset selected user passwords to a shared lab password now? (Y/n)" }
                if ($resetExistingChoice -ne 'n') {
                    $agentPassword = Read-Host "  Shared lab password to set (blank = generate)"
                    if (-not $agentPassword) {
                        $agentPassword = New-AALabPassword
                    }
                } else {
                    $agentPassword = Read-Host "  Enter the existing shared password to store in Key Vault"
                }
            }

            if ($resetExistingChoice -ne 'n') {
                Write-Host "  Resetting selected user passwords..." -NoNewline
                $resetOk = 0
                foreach ($agent in $agents) {
                    $upn = Get-AgentUpn -Agent $agent -Domain $domain
                    if ($script:AAM365AzConfigDir) {
                        Invoke-AAM365Az -Arguments @('ad','user','update','--id',$upn,'--password',$agentPassword,'--force-change-password-next-sign-in','false','-o','none') 2>$null | Out-Null
                    } else {
                        az ad user update --id $upn --password $agentPassword --force-change-password-next-sign-in false -o none 2>$null
                    }
                    if ($LASTEXITCODE -eq 0) { $resetOk++ }
                }
                Write-Host " [OK] $resetOk/$($agents.Count) passwords reset" -ForegroundColor Green
                Write-AASecretLine -Label 'Shared lab password' -Secret $agentPassword
            } else {
                Write-Host "  [INFO] Passwords were not reset; the entered password will be stored for ROPC." -ForegroundColor DarkYellow
            }
            Write-Host "  (Password will be stored in Key Vault at Step 5.)" -ForegroundColor Gray
        }
        Write-Host ""
    } else {
        Write-Host "=== Step 1: Creating agent accounts in Entra ID ===" -ForegroundColor Cyan
        $agentPassword = New-AALabPassword
        $existCount = 0
        $createCount = 0

        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            Write-Host "  Creating $($agent.displayName) ($upn)..." -NoNewline

            if ($DryRun) { Write-Host " [DRY-RUN]" -ForegroundColor DarkYellow; continue }

            $existingJson = if ($script:AAM365AzConfigDir) {
                Invoke-AAM365Az -Arguments @('ad','user','show','--id',$upn,'-o','json') 2>$null
            } else {
                az ad user show --id $upn -o json 2>$null
            }
            $existing = $existingJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host " [EXISTS]" -ForegroundColor DarkYellow
                $existCount++
            } else {
                $createErr = if ($script:AAM365AzConfigDir) {
                    Invoke-AAM365Az -Arguments @('ad','user','create','--display-name',$agent.displayName,'--user-principal-name',$upn,'--password',$agentPassword,'--force-change-password-next-sign-in','false','-o','json') 2>&1
                } else {
                    az ad user create --display-name $agent.displayName --user-principal-name $upn `
                        --password $agentPassword --force-change-password-next-sign-in false -o json 2>&1
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-Host " [FAIL] $createErr" -ForegroundColor Red
                } else {
                    Write-Host " [OK]" -ForegroundColor Green
                    $createCount++
                }
            }
        }

        # Set usage location + department + jobTitle via Graph PATCH
        $gt = Get-AAGraphAccessToken
        $graphHeaders = @{Authorization="Bearer $gt"; 'Content-Type'='application/json'}
        foreach ($agent in $agents) {
            $upn = Get-AgentUpn -Agent $agent -Domain $domain
            if (-not $DryRun) {
                $userId = if ($script:AAM365AzConfigDir) {
                    Invoke-AAM365Az -Arguments @('ad','user','show','--id',$upn,'--query','id','-o','tsv') 2>$null
                } else {
                    az ad user show --id $upn --query id -o tsv 2>$null
                }
                if ($userId) {
                    $body = @{usageLocation='FR'; department=$agent.department; jobTitle=$agent.jobTitle} | ConvertTo-Json
                    Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$userId" `
                        -Headers $graphHeaders -Body $body -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        # Password handling: if ALL users existed, the generated password was never applied
        if ($existCount -eq $agents.Count -and $createCount -eq 0 -and -not $DryRun) {
            Write-Host ""
            Write-Host "  All agents already exist." -ForegroundColor Yellow
            if ($installBoundParams.ContainsKey('AgentPassword')) {
                # -AgentPassword provided explicitly on command line - use it directly
                $agentPassword = $installBoundParams['AgentPassword']
                Write-Host "  Using provided -AgentPassword." -ForegroundColor Green
            } else {
                Write-Host "  The wizard will RESET their passwords to a new shared password." -ForegroundColor Yellow
                Write-Host "  This requires Global Admin (already verified in prerequisites)." -ForegroundColor Gray
                $resetChoice = if ($Auto) { 'Y' } else { Read-Host "  Reset all agent passwords now? (Y/n)" }
                if ($resetChoice -eq 'n') {
                    Write-Host "  [SKIP] You must provide the password at Step 5." -ForegroundColor DarkYellow
                    Write-Host "  Tip: re-run with -AgentPassword 'yourpassword'" -ForegroundColor Gray
                } else {
                    Write-Host "  Resetting passwords..." -NoNewline
                    $resetOk = 0
                    foreach ($agent in $agents) {
                        $upn = Get-AgentUpn -Agent $agent -Domain $domain
                        if ($script:AAM365AzConfigDir) {
                            Invoke-AAM365Az -Arguments @('ad','user','update','--id',$upn,'--password',$agentPassword,'--force-change-password-next-sign-in','false','-o','none') 2>$null | Out-Null
                        } else {
                            az ad user update --id $upn --password $agentPassword --force-change-password-next-sign-in false -o none 2>$null
                        }
                        if ($LASTEXITCODE -eq 0) { $resetOk++ }
                    }
                    Write-Host " [OK] $resetOk/$($agents.Count) passwords reset" -ForegroundColor Green
                    Write-AASecretLine -Label 'New shared password' -Secret $agentPassword
                }
            }
        } elseif ($createCount -gt 0) {
            Write-AASecretLine -Label 'Password for new agents' -Secret $agentPassword
        }
        Write-Host "  (Password will be stored automatically in Step 5.)" -ForegroundColor Gray
        Write-Host ""
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '1' -Value ([ordered]@{
        activity = 'Create or select agent users'
        completedAt = (Get-Date).ToString('o')
        userMode = $userMode
        agentCount = @($agents).Count
        agents = @($agents | ForEach-Object {
            [ordered]@{
                sam = $_.sam
                upn = Get-AgentUpn -Agent $_ -Domain $domain
                displayName = $_.displayName
                department = $_.department
                keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $domain
            }
        })
    })

    if (-not $DryRun) {
        Write-Host ""
        Write-Host "=== Step 1b: Persona profile photos ===" -ForegroundColor Cyan
        Write-Host "  Uploads Images\\Characters persona images to Entra user profile photos." -ForegroundColor Gray
        Write-Host "  Photos improve Teams, Outlook, portal screenshots, and storyline recognition." -ForegroundColor Gray
        $uploadPhotos = if ($Auto) { 'Y' } else { Read-Host "  Upload persona photos now? (Y/n)" }
        if ($uploadPhotos -notin @('n','N','no','NO')) {
            $oldGraphToken = $env:CLAUDIA_GRAPH_TOKEN
            if ($script:AAM365AzConfigDir) { $env:CLAUDIA_GRAPH_TOKEN = Get-AAGraphAccessToken }
            try {
                & (Join-Path $installRoot 'tools\Set-EntraUserPhotos.ps1') -ConfigPath $ConfigPath -SkipMissing
            } catch {
                Write-Host "  [WARN] Persona photo upload did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "         You can retry later with: .\tools\Set-EntraUserPhotos.ps1 -SkipMissing" -ForegroundColor DarkYellow
            } finally {
                if ($null -ne $oldGraphToken) { $env:CLAUDIA_GRAPH_TOKEN = $oldGraphToken }
                else { Remove-Item Env:\CLAUDIA_GRAPH_TOKEN -ErrorAction SilentlyContinue }
            }
        } else {
            Write-Host "  [SKIP] Persona photos can be uploaded later with .\tools\Set-EntraUserPhotos.ps1 -SkipMissing" -ForegroundColor DarkYellow
        }
        Write-Host ""
    }
}

