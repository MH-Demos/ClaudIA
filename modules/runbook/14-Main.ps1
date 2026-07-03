# =============================================================================
# MAIN
# =============================================================================
$today = Get-Date
if (-not $bSkipWeekendCheck -and $today.DayOfWeek -in @('Saturday','Sunday')) {
    Write-Output "Weekend detected -- skipping. Use SkipWeekendCheck=True to override."
    return
}

Write-Output "=== AI Agent Daily Activity -- $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
Write-Output "Mode: $ActivityMode | Emails: $bSendEmails | OpenAI: $OaiDeployment"

# -- Connect to Azure (Managed Identity) + load secrets ----------------------
Write-Output "Connecting via Managed Identity..."
Connect-AzAccount -Identity | Out-Null
if ($subscriptionId) {
    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Output "Azure context set to subscription $subscriptionId."
}
$tenantId     = Get-AutomationVariable -Name 'AgentTenantId'
$appId        = Get-AutomationVariable -Name 'AgentAppId'
$keyVaultName = Get-AutomationVariable -Name 'AgentKeyVaultName'
$clientSecretName = Get-AutomationVariable -Name 'AgentClientSecretName'
$clientSecret = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $clientSecretName
$keyVaultNameForLog = ConvertTo-AAPlainString $keyVaultName
if ([string]::IsNullOrWhiteSpace($clientSecret)) {
    Write-Warning "  [AUTH] Client secret '$clientSecretName' is empty or missing in Key Vault '$keyVaultNameForLog'. Re-run Step 5."
}
Write-Output "Key Vault credentials loaded from $keyVaultNameForLog."
Initialize-AdxIngestion

# -- Get Azure OpenAI token via Managed Identity (RBAC) ----------------------
Write-Output "Acquiring OpenAI token via Managed Identity RBAC..."
$oaiToken = Get-OaiToken
$script:oaiTokenAcquiredAt = Get-Date
Write-Output "OpenAI token acquired (length=$($oaiToken.Length))"

function Update-OaiTokenIfStale {
    # Managed Identity tokens live ~60 min; a full run (10 agents + threads)
    # can exceed that, and every Invoke-OAI after expiry used to fail with 401.
    # Get-AzAccessToken re-issues from the Az context, so refresh is cheap.
    # NOTE: returns nothing (callers read $script:oaiTokenCurrent) so that
    # Write-Output logging does not pollute a captured return value.
    if (((Get-Date) - $script:oaiTokenAcquiredAt).TotalMinutes -le 45) { return }
    try {
        $script:oaiTokenCurrent = Get-OaiToken
        $script:oaiTokenAcquiredAt = Get-Date
        Write-Output "  [AUTH] OpenAI token refreshed"
    }
    catch {
        Write-Warning "  [AUTH] OpenAI token refresh failed (keeping current token): $($_.Exception.Message)"
    }
}
$script:oaiTokenCurrent = $oaiToken

# -- Filter agents if specified -----------------------------------------------
$activeAgents = $agents
if ($RunAsAgent) {
    $activeAgents = $agents | Where-Object { $_.Sam -eq $RunAsAgent }
    if (-not $activeAgents) { throw "Agent '$RunAsAgent' not found" }
}

$totalFiles  = 0
$totalEmails = 0
$script:totalFileOps = 0
$totalExternalAi = 0
$totalInsiderRisk = 0
$dayContext  = "Today is $(Get-Date -Format 'dddd d MMMM yyyy'). It is a normal workday."

# -- Determine activity mode timing ------------------------------------------
switch ($ActivityMode) {
    'morning'   { $activeAgents | ForEach-Object { $_.EndHour   = [Math]::Min($_.EndHour, 13) } }
    'afternoon' { $activeAgents | ForEach-Object { $_.StartHour = [Math]::Max($_.StartHour, 13) } }
    'burst'     { $activeAgents | ForEach-Object { $_.EndHour   = $_.StartHour + 2 } }
}

foreach ($agent in $activeAgents) {
    $upn = $agent.Upn
    Write-Output "`n========================================================"
    Write-Output "  $($agent.Name) | $($agent.Dept) | $($agent.Title)"
    Write-Output "  Working hours: $($agent.StartHour):00 - $($agent.EndHour):00"
    Write-Output "========================================================"

    # Throttle-aware pacing: if Graph returned 429s in the last 5 minutes, cool
    # down before this agent instead of cascading throttling across the run.
    if ($script:graphLastThrottleAt -and ((Get-Date) - $script:graphLastThrottleAt).TotalMinutes -lt 5) {
        $coolDown = Get-Random -Minimum 30 -Maximum 61
        Write-Output "  [THROTTLE] Graph throttling detected ($($script:graphThrottle429Count) x 429 so far) -- cooling down ${coolDown}s"
        Start-Sleep -Seconds $coolDown
    }

    # Refresh the shared OpenAI token if it is close to expiry.
    Update-OaiTokenIfStale
    $oaiToken = $script:oaiTokenCurrent

    # -- Authenticate as this agent (ROPC) ------------------------------------
    $agentPwdSecretName = Get-AutomationVariable -Name "AgentPwdSecret-$($agent.Sam)" -ErrorAction SilentlyContinue
    if (-not $agentPwdSecretName) { $agentPwdSecretName = $agent.SecretName }
    $agentPwd = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $agentPwdSecretName
    if ([string]::IsNullOrWhiteSpace($agentPwd)) {
        Write-Warning "  [AUTH] Password secret '$(ConvertTo-AAPlainString $agentPwdSecretName)' is empty or missing in Key Vault '$keyVaultNameForLog'. Re-run Step 1 and Step 5 with a non-empty shared password."
        continue
    }
    try {
        $token = Get-ROPCToken -Username $upn -Password $agentPwd `
            -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
        Write-Output "  [AUTH] ROPC token acquired"
    }
    catch {
        Write-Warning "  [AUTH] ROPC failed for ${upn}: $($_.Exception.Message)"
        continue
    }

    # OneLake token for Fabric workload (storage audience)
    $oneLakeToken = $null
    if ($agent.Workload -eq 'Fabric' -and $fabricEnabled) {
        try {
            $oneLakeToken = Get-OneLakeToken -Username $upn -Password $agentPwd `
                -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
            Write-Output "  [AUTH] OneLake token acquired"
        } catch {
            Write-Warning "  [AUTH] OneLake token failed: $($_.Exception.Message)"
        }
    }

    # Reset label cache per agent (each agent has a different delegated token)
    # Team cache is NOT reset -- channels are the same for all agents
    $script:labelCache = $null

    $me = Invoke-Graph -Token $token -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,displayName'
    $agentUserId = $me.id
    Write-Output "  [ID]   $($me.displayName) ($agentUserId)"

    # -- Decide today's file count + types ------------------------------------
    $fileCount  = Get-Random -Minimum $agent.FilesPerDay[0] -Maximum ($agent.FilesPerDay[1] + 1)
    $emailCount = if ($bSendEmails) { Get-Random -Minimum $agent.EmailsPerDay[0] -Maximum ($agent.EmailsPerDay[1] + 1) } else { 0 }

            $deptFiles = $fileTypes[$agent.ContentDept]
            if (-not $deptFiles) { $deptFiles = $fileTypes['Sales'] }
            $selectedFileTypes = $deptFiles | Get-Random -Count ([Math]::Min($fileCount, $deptFiles.Count))

    $workloadAliases = switch ($agent.Workload) {
        'Teams'    { @('teams','microsoft teams') }
        'Chat'     { @('chat','teams','microsoft teams') }
        'Lists'    { @('lists','microsoft lists','sharepoint','spo') }
        'Fabric'   { @('fabric','microsoft fabric','sharepoint','spo') }
        'Meetings' { @('meetings','teams','microsoft teams') }
        'ExternalAI' { @('externalai','external ai','ai','foundry','irm','insider risk','insider risk management') }
        default    { @('spo','sharepoint','sharepoint online','files') }
    }
    $workloadAliases += @('fileops','activity explorer','activityexplorer','audit')
    if (-not (Test-ServiceRequested -Aliases $workloadAliases)) {
        $selectedFileTypes = @()
    }
    if (-not (Test-ServiceRequested -Aliases @('mail','email','exchange','exchange online','outlook'))) {
        $emailCount = 0
    }

    # -- Build random schedule for the day ------------------------------------
    $schedule = Get-RandomWorkSchedule -StartHour $agent.StartHour -EndHour $agent.EndHour `
        -FileCount $selectedFileTypes.Count -EmailCount $emailCount

    Write-Output "  [PLAN] $($selectedFileTypes.Count) files + $emailCount emails across $($agent.StartHour):00-$($agent.EndHour):00"

    # -- Execute activities in schedule order ---------------------------------
    $fileIdx  = 0
    $emailIdx = 0

    for ($si = 0; $si -lt $schedule.Count; $si++) {
        $activity = $schedule[$si]
        $tH = [int][Math]::Floor($activity.Time / 60)
        $tM = [int]($activity.Time % 60)
        $timeStr = '{0:D2}:{1:D2}' -f $tH, $tM

        if ($activity.Type -eq 'file' -and $fileIdx -lt $selectedFileTypes.Count) {
            $ft   = $selectedFileTypes[$fileIdx]
            $date = Get-Date -Format 'yyyy-MM-dd'

            # -- Generate content via Azure OpenAI or image scan -----------------
            $content = $null
            $bytes   = $null
            $userPrompt = ''

            if ($ft.Ext -eq '.png') {
                # Scanned document image: generate PNG with PII text (no AI needed)
                try {
                    $bytes = New-ScanImage -Type $ft.Type -AgentName $agent.Name -Dept $agent.Dept
                    $content = "PNG scan generated locally for $($ft.Type) by $($agent.Name) in $($agent.Dept)."
                    Write-Output "    [$timeStr] Scan generated: $($ft.Type) ($($bytes.Length) bytes, .png)"
                } catch {
                    Write-Warning "    [$timeStr] Scan failed for $($ft.Type): $($_.Exception.Message)"
                    $fileIdx++; continue
                }
            } else {
                # AI-generated text content
                $fullSystemPrompt = $agent.Prompt + "`n`n" + $sitReference
                $userPrompt = "$dayContext`n`nGenerate this document: $($ft.Prompt)`n`nDocument date: $date. Use different names/numbers each time. Output ONLY the document content, no explanations."

            # Rich formats (SVG, HTML, JSON, MD) need more tokens
            $maxTok = switch ($ft.Ext) {
                '.svg'  { 4000 }
                '.html' { 3500 }
                '.json' { 3000 }
                '.md'   { 3000 }
                '.xml'  { 3000 }
                '.csv'  { 2500 }
                default { 2000 }
            }

            try {
                $content = Invoke-OAI -OaiToken $oaiToken -SystemPrompt $fullSystemPrompt -UserPrompt $userPrompt -MaxTokens $maxTok -UserId $upn
                Write-Output "    [$timeStr] AI generated: $($ft.Type) ($($content.Length) chars, $($ft.Ext))"
            }
            catch {
                Write-Warning "    [$timeStr] OAI failed for $($ft.Type): $($_.Exception.Message)"
                $content = "$($ft.Type) - $date - Generated by $($agent.Name)`nsocial security number: $(Get-Random -Min 100 -Max 899)-$(Get-Random -Min 10 -Max 99)-$(Get-Random -Min 1000 -Max 9999)`nrouting number: $(Get-Random -Min 100000000 -Max 999999999)`naccount number: $(Get-Random -Min 1000000000 -Max 9999999999)"
            }
            } # end else (AI content)

            # -- Upload to SharePoint or execute workload-specific action ----
            $fileName  = "$($ft.Type)_${date}_$(Get-Random -Min 100 -Max 999)$($ft.Ext)"
            $folder    = $agent.Dept
            $workload  = if ($agent.Workload) { $agent.Workload } else { 'SPO' }
            $service = switch ($workload) {
                'Teams'    { 'Microsoft Teams' }
                'Chat'     { 'Microsoft Teams Chat' }
                'Lists'    { 'Microsoft Lists' }
                'Fabric'   { 'Microsoft Fabric' }
                'Meetings' { 'Microsoft Teams' }
                default    { 'SharePoint Online' }
            }
            $action = switch ($workload) {
                'Teams'    { 'Posted' }
                'Chat'     { 'SentChatMessage' }
                'Lists'    { 'UploadedListData' }
                'Fabric'   { 'UploadedDataset' }
                'Meetings' { 'UploadedMeetingNotes' }
                default    { 'Uploaded' }
            }
            $targetType = if ($ft.Ext -eq '.png') { 'Image' } else { 'File' }
            $targetPath = "$folder/$fileName"
            $recipientName = ''
            $recipientUPN = ''
            if (-not $bytes) {
                if ([string]::IsNullOrWhiteSpace($content)) {
                    $content = "$($ft.Type) - $date - Generated by $($agent.Name)"
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            }
            $labelFriendlyMode = Test-ServiceRequested -Aliases @('fileops','activity explorer','activityexplorer','audit','labels','sensitivity labels','purview')
            if ($labelFriendlyMode -and -not (Test-AASensitivityLabelSupportedExtension -Extension $ft.Ext)) {
                try {
                    $converted = ConvertTo-AALabelFriendlyFile -Type $ft.Type -Extension $ft.Ext -Content $content -Bytes $bytes
                    if ($converted.Converted) {
                        $oldExt = $ft.Ext
                        $ft.Ext = $converted.Ext
                        $bytes = $converted.Bytes
                        $content = $converted.Content
                        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($fileName) + $ft.Ext
                        $targetType = 'File'
                        $targetPath = "$folder/$fileName"
                        Write-Output "    [$timeStr] Converted $oldExt to $($ft.Ext) for Purview label/Activity Explorer support: $fileName"
                    }
                }
                catch {
                    Write-Warning "    [$timeStr] Supported-format conversion failed for ${fileName}: $($_.Exception.Message)"
                }
            }

            try {
                switch ($workload) {
                    'Teams' {
                        # Post content as a Teams channel message (Julien - HR, Olivier - Sales)
                        $htmlContent = "<h3>$($ft.Type) - $date</h3><pre>$([System.Net.WebUtility]::HtmlEncode($content.Substring(0, [math]::Min($content.Length, 2000))))</pre>"
                        $posted = Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $htmlContent
                        if ($posted) {
                            Write-Output "    [$timeStr] Teams post: $($ft.Type) in /$($agent.Dept)"
                            $totalFiles++
                        } else {
                            Write-Warning "    [$timeStr] Teams post NOT delivered: $($ft.Type) in /$($agent.Dept)"
                        }
                    }
                    'Chat' {
                        # Send as Teams 1:1 chat message to a random colleague (Karim - Legal)
                        $colleagues = $agents | Where-Object { $_.Sam -ne $agent.Sam -and $_.Dept -eq $agent.Dept }
                        if (-not $colleagues) { $colleagues = $agents | Where-Object { $_.Sam -ne $agent.Sam } }
                        $target = $colleagues | Get-Random
                        $recipientName = $target.Name
                        $recipientUPN = "$($target.Sam)@$domain"
                        $targetId = Invoke-Graph -Token $token -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($target.Sam)@$domain" | Select-Object -ExpandProperty id
                        $chatBody = @{
                            chatType = 'oneOnOne'
                            members = @(
                                @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($agentUserId)')"; roles=@('owner') }
                                @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$targetId')"; roles=@('owner') }
                            )
                        } | ConvertTo-Json -Depth 4
                        $chat = Invoke-Graph -Token $token -Method POST -Uri "https://graph.microsoft.com/v1.0/chats" -Body ([System.Text.Encoding]::UTF8.GetBytes($chatBody)) -ContentType 'application/json'
                        if ($chat.id) {
                            $msgBody = @{ body = @{ contentType = 'text'; content = $content.Substring(0, [math]::Min($content.Length, 4000)) } } | ConvertTo-Json -Depth 3
                            Invoke-Graph -Token $token -Method POST -Uri "https://graph.microsoft.com/v1.0/chats/$($chat.id)/messages" -Body ([System.Text.Encoding]::UTF8.GetBytes($msgBody)) -ContentType 'application/json' | Out-Null
                            Write-Output "    [$timeStr] Teams chat: $($ft.Type) -> $($target.Name)"
                        }
                        $totalFiles++
                    }
                    'Lists' {
                        # Upload as structured CSV to SharePoint (Claire - Finance)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] SPO list data: $folder/$fileName"
                        $totalFiles++
                    }
                    'Fabric' {
                        # Upload contextualized data files to OneLake Lakehouse + SharePoint
                        # Organized by format: datasets/, schemas/, reports/, dashboards/, diagrams/
                        $subFolder = switch -Wildcard ($ft.Ext) {
                            '.csv'  { 'datasets' }
                            '.json' { 'schemas' }
                            '.md'   { 'reports' }
                            '.html' { 'dashboards' }
                            '.svg'  { 'diagrams' }
                            '.xml'  { 'integrations' }
                            '.txt'  { 'logs' }
                            default { 'misc' }
                        }
                        $fabricFolder = "$folder/$subFolder"
                        $targetPath = "$fabricFolder/$fileName"
                        if (-not $bytes) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($content) }

                        # Primary: OneLake Lakehouse (if enabled + token available)
                        if ($oneLakeToken -and $fabricWorkspaceId -and $fabricLakehouseId) {
                            try {
                                Write-OneLake -Token $oneLakeToken -WorkspaceId $fabricWorkspaceId `
                                    -LakehouseId $fabricLakehouseId -Path "$fabricFolder/$fileName" -Content $bytes
                                Write-Output "    [$timeStr] OneLake ($subFolder): $fabricFolder/$fileName"
                            } catch {
                                Write-Warning "    [$timeStr] OneLake upload failed: $($_.Exception.Message)"
                            }
                        }

                        # Secondary: SharePoint (always, for DLP/audit/auto-labeling coverage)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$fabricFolder/${fileName}:/content"
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] SPO ($subFolder): $fabricFolder/$fileName"
                        $totalFiles++
                    }
                    'Meetings' {
                        # Upload meeting notes to SharePoint + post summary in Teams (Olivier - Sales)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        if (-not $bytes) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($content) }
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] Meeting notes: $folder/$fileName"
                        # Also post a summary in Teams
                        $summary = "<b>Meeting notes</b> - $($ft.Type) ($date)<br/><small>By $($agent.Name) ($($agent.Title))</small>"
                        $null = Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $summary
                        $totalFiles++
                    }
                    default {
                        # Default SPO file upload (Wave 1 agents)
                        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
                        $uploadResult = Invoke-Graph -Token $token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'application/octet-stream'
                        Write-Output "    [$timeStr] Uploaded: $folder/$fileName"
                        $totalFiles++
                    }
                }

                # -- Apply sensitivity label based on dept + file type --------
                $labels = Get-SensitivityLabels -Token $token
                $targetLabel = Resolve-LabelForFile -Dept $agent.ContentDept -FileType $ft.Type -Labels $labels
                $labelApplied = ''
                if ($targetLabel -and $uploadResult.id -and (Test-AASensitivityLabelSupportedExtension -Extension $ft.Ext)) {
                    $targetLabelName = Get-LabelName -Label $targetLabel
                    $ok = Apply-FileLabel -Token $token -SiteId $spoSiteId `
                        -ItemId $uploadResult.id -LabelId $targetLabel.id -LabelName $targetLabelName
                    if ($ok) {
                        $labelApplied = $targetLabelName
                        Write-Output "    [$timeStr] Label: $labelApplied"
                        Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                            -Action 'SensitivityLabelApplied' -TargetName $fileName -TargetPath $targetPath `
                            -LabelName $targetLabelName -LabelId $targetLabel.id `
                            -ExtraProperties @{
                                SourceActivity = 'FileUpload'
                                SourceWorkload = $workload
                                FileType = $ft.Type
                                FileExtension = $ft.Ext
                                Folder = $folder
                                ContentDepartment = $agent.ContentDept
                            }
                    } else {
                        Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                            -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                            -LabelName $targetLabelName -LabelId $targetLabel.id `
                            -Outcome 'Failed' -ErrorMessage $script:lastLabelError `
                            -ExtraProperties @{
                                SourceActivity = 'FileUpload'
                                SourceWorkload = $workload
                                FileType = $ft.Type
                                FileExtension = $ft.Ext
                                Folder = $folder
                                ContentDepartment = $agent.ContentDept
                            }
                    }
                }
                elseif ($targetLabel -and $uploadResult.id) {
                    $targetLabelName = Get-LabelName -Label $targetLabel
                    Write-Warning "    [LABEL] Skipped unsupported file type $($ft.Ext) for $fileName"
                    Push-LabelActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                        -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                        -LabelName $targetLabelName -LabelId $targetLabel.id `
                        -Outcome 'Skipped' -ErrorMessage "Unsupported file type $($ft.Ext) for Graph assignSensitivityLabel." `
                        -ExtraProperties @{
                            SourceActivity = 'FileUpload'
                            SourceWorkload = $workload
                            FileType = $ft.Type
                            FileExtension = $ft.Ext
                            Folder = $folder
                            ContentDepartment = $agent.ContentDept
                        }
                }

                # -- Log enriched activity to ADX ------------------------------
                $activityContent = if ([string]::IsNullOrWhiteSpace($content)) { "Binary file $fileName ($($bytes.Length) bytes)" } else { $content }
                Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                    -ActivityType $workload -Detail "$fileName ($($activityContent.Length) chars)" `
                    -TokensIn ([Math]::Round($activityContent.Length / 4)) -TokensOut ([Math]::Round($activityContent.Length / 4)) `
                    -PromptContent $userPrompt -ResponseContent $activityContent `
                    -Properties @{
                        Service = $service
                        Action = $action
                        Workload = $workload
                        TargetName = $fileName
                        TargetType = $targetType
                        TargetPath = $targetPath
                        FileType = $ft.Type
                        FileExtension = $ft.Ext
                        Folder = $folder
                        ContentDepartment = $agent.ContentDept
                        SensitivityLabel = $labelApplied
                        RecipientName = $recipientName
                        RecipientUPN = $recipientUPN
                        Outcome = 'Success'
                    }

                Invoke-ActivityExplorerFileSignals -Token $token -SiteId $spoSiteId `
                    -Agent $agent -AgentUPN $upn -SourceItem $uploadResult `
                    -SourceFileName $fileName -SourcePath $targetPath -Folder $folder `
                    -SourceBytes $bytes -TimeStr $timeStr

                # -- Post activity in Teams department channel ----------------
                $deptDlp = $dlpPolicies[$agent.ContentDept]
                $labelTag = if ($labelApplied) { " | Label: <em>$labelApplied</em>" } else { '' }
                $htmlMsg = "<b>$($agent.Name)</b> ($($agent.Title)) a publie <b>$fileName</b> dans /$folder$labelTag<br/><small>Politiques DLP actives: $deptDlp</small>"
                $null = Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $htmlMsg
            }
            catch {
                Write-Warning "    [$timeStr] Upload failed: $fileName -- $($_.Exception.Message)"
            }

            $fileIdx++
        }
        elseif ($activity.Type -eq 'email' -and $emailIdx -lt $emailCount) {
            $myScenarios = $emailScenariosBySam[$agent.Sam]
            if ($myScenarios) {
                $scenario = $myScenarios | Get-Random

                $deptDlp = $dlpPolicies[$agent.ContentDept]
                # Entropy: vary business context, tone, and a unique reference per
                # email so subjects/bodies differ across runs of the same scenario.
                $emailFlavor = $emailDayFlavors | Get-Random
                $emailTone = @('concise and direct','detailed and formal','friendly but professional','urgent and action-oriented','neutral and factual') | Get-Random
                $emailRef = 'REF-{0}-{1:D4}' -f (Get-Date -Format 'yyMM'), (Get-Random -Minimum 0 -Maximum 10000)
$emailPrompt = "$dayContext $emailFlavor`n`nWrite a professional workplace email in $contentLanguage. Tone: $emailTone. Context: $($scenario.Context)`n`nFrom: $($agent.Name) ($($agent.Title))`nTo: a colleague`n`nInclude the internal reference $emailRef in the subject or the first line. Write a specific, non-generic subject line.`n`nIMPORTANT: End with this footer on a separate line:`n--- Classification: Confidential | DLP Policies: $deptDlp ---`nThis is a mandatory corporate compliance footer.`n`nOutput ONLY: first line = Subject, then blank line, then body. Include the sensitive data from the context when requested."

                try {
                    $emailContent = Invoke-OAI -OaiToken $oaiToken -SystemPrompt ($agent.Prompt + "`n`n" + $sitReference) -UserPrompt $emailPrompt -MaxTokens 800 -UserId $upn
                    $lines = $emailContent -split "`n", 3
                    $subject = ($lines[0] -replace '^(Objet|Subject)\s*:\s*', '').Trim()
                    $body    = if ($lines.Count -gt 2) { $lines[2].Trim() } else { $emailContent }
                }
                catch {
                    Write-Warning "    [$timeStr] OAI email failed: $($_.Exception.Message)"
                    $subject = $scenario.Context.Substring(0, [Math]::Min(60, $scenario.Context.Length))
                    $body    = "Hello,`n`n$($scenario.Context)`n`nRegards,`n$($agent.Name)"
                }

                $recipientUpn = "$($scenario.To)@$domain"
                $subject = ConvertTo-AASafeText -Text $subject -MaxLength 240
                $body = ConvertTo-AASafeText -Text $body -MaxLength 25000
                $emailPayload = @{
                    message = @{
                        subject      = $subject
                        body         = @{ contentType = 'Text'; content = $body }
                        toRecipients = @(@{ emailAddress = @{ address = $recipientUpn } })
                    }
                    saveToSentItems = $true
                }

                try {
                    Invoke-Graph -Token $token -Method POST `
                        -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $emailPayload | Out-Null
                    Write-Output "    [$timeStr] Email: $($agent.Sam) -> $($scenario.To) | $subject"
                    $totalEmails++
                    $recipientAgent = $agentLookup[$scenario.To]
                    $recipientName = if ($recipientAgent) { $recipientAgent.Name } else { $scenario.To }
                    Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                        -ActivityType 'email' -Detail "To:$($scenario.To) | $subject" `
                        -PromptContent $emailPrompt -ResponseContent $body `
                        -Properties @{
                            Service = 'Exchange Online'
                            Action = 'SentEmail'
                            Workload = 'Exchange'
                            TargetName = $subject
                            TargetType = 'Email'
                            RecipientName = $recipientName
                            RecipientUPN = $recipientUpn
                            Subject = $subject
                            Scenario = $scenario.Context
                            Outcome = 'Success'
                        }
                }
                catch {
                    Write-Warning "    [$timeStr] Email failed: $($_.Exception.Message)"
                }
            }
            $emailIdx++
        }

        # -- Simulate human delay between activities --------------------------
        if ($si -lt ($schedule.Count - 1)) {
            $nextTime = $schedule[$si + 1].Time
            $delay    = Get-DelaySeconds -CurrentTimeMin $activity.Time -NextTimeMin $nextTime
            Write-Output "    ... waiting ${delay}s (simulating work)"
            Start-Sleep -Seconds $delay
        }
    }

    # -- Compliance scan: detect unlabeled files in department folder --------
    $unlabeled = Get-UnlabeledFiles -Token $token -SiteId $spoSiteId -Folder $agent.Dept
    if ($unlabeled -and $unlabeled.Count -gt 0) {
        $fileList = ($unlabeled | Select-Object -First 5 | ForEach-Object { $_.name }) -join ', '
        $complianceHtml = "&#9888; <b>Compliance alert ($($agent.Dept))</b>: $($unlabeled.Count) unlabeled file(s) detected.<br/><small>Files: $fileList</small><br/><small>Recommended action: apply a sensitivity label in Microsoft Purview.</small>"
        $null = Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $complianceHtml
        Write-Output "  [SCAN] $($unlabeled.Count) unlabeled files in /$($agent.Dept)"
    }
    else {
        $complianceHtml = "&#9989; <b>Compliance ($($agent.Dept))</b>: All files are labeled. Active DLP policies: $($dlpPolicies[$agent.ContentDept])"
        $null = Post-TeamsActivity -Token $token -Dept $agent.Dept -HtmlContent $complianceHtml
        Write-Output "  [SCAN] All files labeled in /$($agent.Dept)"
    }

    # -- Copilot M365 queries (Wave 2 agents with Copilot license) -----------
    $copilotCount = 0
    $copilotQueriesEnabled = $agentConfig.features.copilotQueries -ne $false
    if ($copilotQueriesEnabled -and (Test-ServiceRequested -Aliases @('copilot','microsoft 365 copilot','m365 copilot')) -and $copilotPrompts.ContainsKey($agent.Sam)) {
        try {
            # Generate unique search queries via Azure OpenAI per persona
            $copilotDayContext = "Today is $(Get-Date -Format 'dddd d MMMM yyyy'). Generate queries relevant to this period."
            $aiQueries = Invoke-OAI -OaiToken $oaiToken `
                -SystemPrompt $copilotPrompts[$agent.Sam] `
                -UserPrompt $copilotDayContext -UserId $upn
            $queryList = ($aiQueries -split "`n") | Where-Object { $_.Trim().Length -gt 5 } | Select-Object -First 3
            Write-Output "    [COPILOT] AI generated $($queryList.Count) search queries"
        }
        catch {
            Write-Warning "    [COPILOT] AI query generation failed, using fallback"
            $queryList = @(
                "$($agent.Dept) documents containing social security numbers or bank account data"
                "recent $($agent.Dept) files with sensitive personal data"
                "$($agent.Dept) reports $(Get-Date -Format 'MMMM yyyy')"
            )
        }

        foreach ($query in $queryList) {
            $query = $query.Trim()
            if ($query.Length -lt 5) { continue }
            try {
                $searchBody = @{
                    requests = @(
                        @{
                            entityTypes = @('driveItem')
                            query = @{ queryString = $query }
                            from = 0
                            size = 5
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $searchResult = Invoke-Graph -Token $token -Method POST `
                    -Uri 'https://graph.microsoft.com/v1.0/search/query' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($searchBody)) `
                    -ContentType 'application/json'

                $hitCount = 0
                if ($searchResult.value -and $searchResult.value[0].hitsContainers) {
                    $hitCount = $searchResult.value[0].hitsContainers[0].total
                }
                Write-Output "    [COPILOT] '$($query.Substring(0, [Math]::Min(60, $query.Length)))' -> $hitCount hits"
                $copilotCount++
                Push-AgentActivity -AgentUPN $upn -AgentName $agent.Name -Department $agent.Dept `
                    -ActivityType 'copilot' -Detail "Query: $($query.Substring(0, [Math]::Min(100, $query.Length))) -> $hitCount hits" `
                    -PromptContent $query -ResponseContent "$hitCount hits" `
                    -Properties @{
                        Service = 'Microsoft 365 Copilot'
                        Action = 'Searched'
                        Workload = 'Copilot'
                        TargetName = $query
                        TargetType = 'SearchQuery'
                        SearchQuery = $query
                        HitCount = $hitCount
                        Outcome = 'Success'
                    }

                Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 15)
            }
            catch {
                Write-Warning "    [COPILOT] Search failed: $($_.Exception.Message)"
            }
        }
    }

    # -- Controlled non-Copilot AI interactions (Devon expansion pack) -------
    $externalAiCount = 0
    $externalAiEnabled = $agentConfig.features.externalAiInteractions -eq $true
    $externalAiAliases = @('externalai','external ai','ai','foundry','azure ai foundry','deepseek','claude','grok','llama')
    if ($externalAiEnabled -and $agent.Workload -eq 'ExternalAI' -and (Test-ServiceRequested -Aliases $externalAiAliases)) {
        $externalAiResult = @(Invoke-ExternalAiSimulation -Agent $agent -Token $token -OaiToken $oaiToken -UserUpn $upn)
        foreach ($item in $externalAiResult) {
            if ($item -is [int]) {
                $externalAiCount = [int]$item
            } elseif ($item) {
                Write-Output $item
            }
        }
        $totalExternalAi += $externalAiCount
    }

    # -- Devon IRM data leak sequence ---------------------------------------
    $insiderRiskCount = 0
    $insiderRiskAliases = @('irm','insider risk','insider risk management','purview irm','risk','exfiltration','exfiltrate')
    if ($agent.Sam -eq 'devon.reyes' -and (Test-ServiceRequested -Aliases $insiderRiskAliases)) {
        $insiderRiskCount = Invoke-DevonInsiderRiskSequence -Agent $agent -Token $token -UserUpn $upn
        $totalInsiderRisk += $insiderRiskCount
    }

    Write-Output "  [DONE] $($agent.Name): $fileIdx files, $emailIdx emails, $copilotCount copilot queries, $externalAiCount external AI interactions, $insiderRiskCount insider risk events"
}

