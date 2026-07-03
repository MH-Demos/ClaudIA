# =============================================================================
# MULTI-TURN EMAIL CONVERSATIONS (run after all agents complete individual work)
# Uses $agentLookup for O(1) agent resolution and caches ROPC tokens per sender.
# =============================================================================
$totalThreadEmails = 0
$threadTokenCache = @{}  # SAM -> ROPC token (avoid re-auth for same sender)
# Pick 1-2 random threads per run (not all 5 every day)
$runThreadEmails = Test-ServiceRequested -Aliases @('mail','email','exchange','exchange online','outlook','thread','threads')
$validThreads = @()
if ($runThreadEmails) {
    $validThreads = @($emailThreads | Where-Object {
        $valid = $true
        foreach ($m in $_.Messages) {
            if (-not $agentLookup[$m.From] -or -not $agentLookup[$m.To]) {
                $valid = $false
                break
            }
        }
        $valid
    })
} else {
    Write-Output "  [THREAD] Skipped by ServiceFilter."
}
if ($runThreadEmails -and $validThreads.Count -lt $emailThreads.Count) {
    Write-Output "  [THREAD] Skipping $($emailThreads.Count - $validThreads.Count) thread(s) with agents not present in current config."
}
$todayThreads = @()
if ($validThreads.Count -gt 0) {
    $todayThreads = $validThreads | Get-Random -Count ([Math]::Min(2, $validThreads.Count))
}

# Threads run AFTER the whole agent loop: refresh the OpenAI token if stale.
if ($todayThreads.Count -gt 0) {
    Update-OaiTokenIfStale
    $oaiToken = $script:oaiTokenCurrent
}

foreach ($thread in $todayThreads) {
    Write-Output "`n  [THREAD] $($thread.ThreadName) ($($thread.Messages.Count) messages)"
    $conversationHistory = ''

    foreach ($msg in $thread.Messages) {
        # O(1) agent lookup instead of Where-Object filter
        $senderAgent    = $agentLookup[$msg.From]
        $recipientAgent = $agentLookup[$msg.To]
        if (-not $senderAgent -or -not $recipientAgent) {
            Write-Warning "    [THREAD] Agent not found: $($msg.From) or $($msg.To)"
            continue
        }

        # Use cached ROPC token if available, otherwise authenticate
        $senderUpn = $senderAgent.Upn
        if ($threadTokenCache.ContainsKey($msg.From)) {
            $senderToken = $threadTokenCache[$msg.From]
        } else {
            $senderSecretName = Get-AutomationVariable -Name "AgentPwdSecret-$($msg.From)" -ErrorAction SilentlyContinue
            if (-not $senderSecretName) { $senderSecretName = $senderAgent.SecretName }
            $senderPwd = Get-KeyVaultSecretValue -VaultName $keyVaultName -SecretName $senderSecretName
            if (-not $senderPwd) {
                Write-Warning "    [THREAD] No password for $($msg.From)"
                continue
            }
            try {
                $senderToken = Get-ROPCToken -Username $senderUpn -Password $senderPwd `
                    -TenantId $tenantId -ClientId $appId -ClientSecret $clientSecret
                $threadTokenCache[$msg.From] = $senderToken
            }
            catch {
                Write-Warning "    [THREAD] ROPC failed for $senderUpn"
                continue
            }
        }

        # Build the AI prompt with conversation history
        $threadPrompt = @"
You are $($senderAgent.Name), $($senderAgent.Title) at CorpLab.
You are writing an email to $($recipientAgent.Name) ($($recipientAgent.Title)).

$($msg.Instruction)

$(if ($conversationHistory) { "PREVIOUS MESSAGES IN THIS THREAD (include below your reply, prefixed with '> '):`n$conversationHistory" })

IMPORTANT RULES:
- Write in $contentLanguage
- Include the sensitive data mentioned in the instruction using realistic fake values only.
- Follow the MANDATORY DATA FORMAT RULES from your instructions: place the required keyword near each sensitive value so classification engines can match it.
- End with: --- Classification: Confidential | DLP Policies: $($dlpPolicies[$senderAgent.ContentDept]) ---
- Output: first line = Subject (with Re: or Tr: if reply/forward), blank line, then body
"@

        $subject = $null
        $body = $null
        try {
            $emailContent = Invoke-OAI -OaiToken $oaiToken `
                -SystemPrompt ($senderAgent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $threadPrompt -MaxTokens 1200 -UserId $senderUpn
            $elines = $emailContent -split "`n", 3
            $subject = ($elines[0] -replace '^(Objet|Subject|Betreff)\s*:\s*', '').Trim()
            $body = if ($elines.Count -gt 2) { $elines[2].Trim() } else { $emailContent }
        }
        catch {
            Write-Warning "    [THREAD] OAI failed for $($senderAgent.Name) -> $($recipientAgent.Name); using fallback content. $($_.Exception.Message)"
            $subject = "Re: $($thread.ThreadName)"
            $historyNote = if ($conversationHistory) { "`n`nPrior context:`n$conversationHistory" } else { '' }
            $body = @"
Hello $($recipientAgent.Name),

$($msg.Instruction)

For the lab scenario, I am including realistic fake sensitive data only:
- social security number: 123-45-6789
- routing number: 021000021
- account number: 9988776655

Please review and advise on the next action.$historyNote

--- Classification: Confidential | DLP Policies: $($dlpPolicies[$senderAgent.ContentDept]) ---
"@
        }

        try {
            # Send the email
            $recipientUpn = "$($msg.To)@$domain"
            $subject = ConvertTo-AASafeText -Text $subject -MaxLength 240
            $body = ConvertTo-AASafeText -Text $body -MaxLength 25000
            $emailPayload = @{
                message = @{
                    subject = $subject
                    body = @{ contentType = 'Text'; content = $body }
                    toRecipients = @( @{ emailAddress = @{ address = $recipientUpn } } )
                }
                saveToSentItems = $true
            }

            Invoke-Graph -Token $senderToken -Method POST `
                -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' `
                -Body $emailPayload | Out-Null
            Write-Output "    [THREAD] $($senderAgent.Name) -> $($recipientAgent.Name) | $subject"
            $totalThreadEmails++
            Push-AgentActivity -AgentUPN $senderUpn -AgentName $senderAgent.Name -Department $senderAgent.Dept `
                -ActivityType 'thread' -Detail "To:$($msg.To) | $subject" `
                -PromptContent $threadPrompt -ResponseContent $body `
                -Properties @{
                    Service = 'Exchange Online'
                    Action = 'SentThreadEmail'
                    Workload = 'Exchange'
                    TargetName = $thread.ThreadName
                    TargetType = 'EmailThread'
                    RecipientName = $recipientAgent.Name
                    RecipientUPN = $recipientUpn
                    Subject = $subject
                    ThreadName = $thread.ThreadName
                    Scenario = $msg.Instruction
                    Outcome = 'Success'
                }

            # Add to conversation history for next message
            $conversationHistory += "`nFrom: $($senderAgent.Name) ($($senderAgent.Title))`nSubject: $subject`n$body`n---`n"
            $conversationHistory = ConvertTo-AASafeText -Text $conversationHistory -MaxLength 12000

            # Realistic delay between messages in a thread (1-3 minutes)
            Start-Sleep -Seconds (Get-Random -Minimum 10 -Maximum 45)
        }
        catch {
            Write-Warning "    [THREAD] Send failed: $($senderAgent.Name) -> $($recipientAgent.Name): $($_.Exception.Message)"
        }
    }
}

Write-Output "`n=== COMPLETE: $totalFiles files uploaded, $($script:totalFileOps) file operations, $totalEmails emails + $totalThreadEmails thread emails sent, $totalExternalAi external AI interactions, $totalInsiderRisk insider risk events ==="
if ($script:teamsPostFailures -gt 0) {
    Write-Warning "=== TEAMS: $($script:teamsPostFailures) channel post(s) FAILED this run. Last error: $($script:teamsLastPostError). Check ChannelMessage.Send permission / CA policy for ROPC tokens. ==="
}





