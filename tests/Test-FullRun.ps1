<#PSScriptInfo

.VERSION 1.0.0

.GUID ad4455b3-ccda-4d74-922f-1bffd1241295

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Microsoft365 Azure Purview

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Run the agent runbook for all configured users and summarize results

.RELEASENOTES
Initial version metadata for Run the agent runbook for all configured users and summarize results.

#>
<#
.SYNOPSIS
    Run the agent runbook for all configured users and summarize results.
.DESCRIPTION
    Starts one Azure Automation job per selected agent, waits for completion,
    collects job output/diagnostics, waits for ADX ingestion, and prints
    a per-user activity table with Upload, Fabric, Copilot, Email, Teams, and
    status columns.
.EXAMPLE
    .\tests\Test-FullRun.ps1
.EXAMPLE
    .\tests\Test-FullRun.ps1 -Agents ana.rodriguez,priya.sharma -ADXWaitMinutes 2
.EXAMPLE
    .\tests\Test-FullRun.ps1 -Parallel -ThrottleLimit 3
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json'),
    [string[]]$Agents,
    [int]$PollSeconds = 45,
    [int]$ADXWaitMinutes = 2,
    [string[]]$Services,
    [string[]]$AIServices = @('llama','claude','deepseek','grok'),
    [switch]$Parallel,
    [int]$ThrottleLimit = 3,
    [int]$StartRetrySeconds = 60,
    [int]$MaxStartRetries = 10,
    [switch]$NoADXWait,
    [switch]$BrowserAgent,
    [string[]]$BrowserServices = @('owa','copilot'),
    [string]$ExternalRecipient = 'demo.recipient@example.com',
    [switch]$SendEmail,
    [switch]$Sensitive,
    [string]$Label = '',
    [switch]$SkipBrowserPreflight,
    [switch]$ContinueOnFailure
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function ConvertTo-JsonBytes {
    param([Parameter(Mandatory)]$Value, [int]$Depth = 10)
    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    return ,([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Get-AzHeaders {
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Could not acquire Azure management token. Run az login first." }
    @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
}

function Get-JobStatus {
    param([string]$SubId, [string]$ResourceGroup, [string]$AutomationAccount, [string]$JobId)
    $headers = Get-AzHeaders
    (Invoke-RestMethod "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount/jobs/${JobId}?api-version=2023-11-01" -Headers $headers).properties.status
}

function Get-JobOutput {
    param([string]$SubId, [string]$ResourceGroup, [string]$AutomationAccount, [string]$JobId)
    $headers = Get-AzHeaders
    try {
        Invoke-RestMethod "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount/jobs/$JobId/output?api-version=2023-11-01" -Headers $headers
    } catch {
        ''
    }
}

function Get-JobStreams {
    param([string]$SubId, [string]$ResourceGroup, [string]$AutomationAccount, [string]$JobId)
    $headers = Get-AzHeaders
    try {
        @((Invoke-RestMethod "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount/jobs/$JobId/streams?api-version=2023-11-01" -Headers $headers).value)
    } catch {
        @()
    }
}

function New-AgentResult {
    param($Agent)
    [PSCustomObject][ordered]@{
        User = $Agent.sam
        DisplayName = $Agent.displayName
        Department = $Agent.department
        JobId = ''
        JobStatus = 'NotStarted'
        ServiceFilter = ''
        Upload = 0
        SPO = 0
        Fabric = 0
        Teams = 0
        Chat = 0
        Lists = 0
        Meetings = 0
        FileOps = 0
        Email = 0
        Copilot = 0
        Labels = 0
        ExternalAI = 0
        Foundry = 0
        SimAI = 0
        IRM = 0
        CollabSite = 0
        ThreadEmails = 0
        FileOpsOut = 0
        FilesOut = 0
        EmailsOut = 0
        ExternalAIOut = 0
        Warnings = 0
        Errors = 0
        Status = 'pending'
        Comments = ''
    }
}

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

if ($BrowserAgent) {
    $selectedBrowserAgents = @($config.agents | Where-Object { $_.sam -and $_.userPrincipalName })
    if ($Agents -and $Agents.Count -gt 0) {
        $wanted = @{}
        foreach ($a in $Agents) { $wanted[$a.ToLowerInvariant()] = $true }
        $selectedBrowserAgents = @($selectedBrowserAgents | Where-Object {
            $wanted.ContainsKey(([string]$_.sam).ToLowerInvariant()) -or
            ($_.userPrincipalName -and $wanted.ContainsKey(([string]$_.userPrincipalName).ToLowerInvariant())) -or
            ($_.displayName -and $wanted.ContainsKey(([string]$_.displayName).ToLowerInvariant()))
        })
    }
    if (-not $selectedBrowserAgents -or $selectedBrowserAgents.Count -eq 0) { throw "No BrowserAgents selected." }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $browserServicesText = (($BrowserServices -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','
    if (-not $browserServicesText) { $browserServicesText = 'owa,copilot' }

    Write-Host "=== Full BrowserAgent Run Test ===" -ForegroundColor Cyan
    Write-Host "  Agents:   $($selectedBrowserAgents.Count)"
    Write-Host "  Services: $browserServicesText"
    Write-Host "  External: $ExternalRecipient"
    Write-Host ""

    $summary = @()
    foreach ($agent in $selectedBrowserAgents) {
        $status = 'success'
        $comments = ''
        try {
            if (-not $SkipBrowserPreflight) {
                & (Join-Path $repoRoot 'tools\Initialize-BrowserAgents.ps1') `
                    -Agents $agent.sam `
                    -Services $browserServicesText `
                    -SkipAuth `
                    -ContinueOnFailure `
                    -ConfigPath $ConfigPath
            }

            $dailyArgs = @{
                Agent = $agent.sam
                Services = @($browserServicesText -split ',')
                ConfigPath = $ConfigPath
            }
            if ($ExternalRecipient) { $dailyArgs.ExternalRecipient = $ExternalRecipient }
            if ($SendEmail) { $dailyArgs.SendEmail = $true }
            if ($Sensitive) { $dailyArgs.Sensitive = $true }
            if ($Label) { $dailyArgs.Label = $Label }
            & (Join-Path $repoRoot 'tools\Invoke-BrowserAgentDaily.ps1') @dailyArgs
        }
        catch {
            $status = 'failed'
            $comments = $_.Exception.Message
        }

        $summary += [PSCustomObject]@{
            User = $agent.sam
            DisplayName = $agent.displayName
            Department = $agent.department
            BrowserServices = $browserServicesText
            Status = $status
            Comments = $comments
        }

        if ($status -eq 'failed' -and -not $ContinueOnFailure) { break }
    }

    if (-not $NoADXWait) {
        Write-Host "`nWaiting $ADXWaitMinutes minute(s) for ADX ingestion..." -ForegroundColor Gray
        Start-Sleep -Seconds ([Math]::Max(0, $ADXWaitMinutes * 60))
    }

    Write-Host "`n=== BrowserAgent Run Results ===" -ForegroundColor Cyan
    $summary | Format-Table -AutoSize
    Write-Host ""
    & (Join-Path $repoRoot 'tools\Get-BrowserAgentTelemetry.ps1') -SinceMinutes ([Math]::Max(60, $ADXWaitMinutes * 60 + 30)) -ConfigPath $ConfigPath
    return
}

$subId = $config.tenant.subscriptionId
$rg = $config.infrastructure.resourceGroup
$aaName = $config.infrastructure.automationAccountName

az account set -s $subId 2>$null
$headers = Get-AzHeaders

# Resolve Automation RG without relying on the Azure CLI automation extension.
$aaId = az resource list --resource-type Microsoft.Automation/automationAccounts --query "[?name=='$aaName'].id | [0]" -o tsv 2>$null
if (-not $aaId) { throw "Automation Account '$aaName' not found in subscription '$subId'." }
if ($aaId -match '/resourceGroups/([^/]+)/') { $rg = $Matches[1] }

# Warn if the published runbook is stale.
try {
    $publishedRunbook = Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/Invoke-AgentRunbook/content?api-version=2023-11-01" -Headers $headers
    if ($publishedRunbook -notmatch 'return ,\(\[System\.Text\.Encoding\]::UTF8\.GetBytes\(\$json\)\)' -or
        $publishedRunbook -notmatch 'ServiceFilter' -or
        $publishedRunbook -notmatch 'Invoke-ActivityExplorerFileSignals' -or
        $publishedRunbook -notmatch 'external AI interactions' -or
        $publishedRunbook -notmatch 'insider risk events') {
        Write-Host "[WARN] Published runbook may be stale. Run .\tools\Publish-RunbookOnly.ps1 before testing." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] Could not verify published runbook content: $($_.Exception.Message)" -ForegroundColor Yellow
}

$selectedAgents = @($config.agents)
if ($Agents -and $Agents.Count -gt 0) {
    $wanted = @{}
    foreach ($a in $Agents) { $wanted[$a.ToLowerInvariant()] = $true }
    $selectedAgents = @($selectedAgents | Where-Object {
        $wanted.ContainsKey(([string]$_.sam).ToLowerInvariant()) -or
        ($_.userPrincipalName -and $wanted.ContainsKey(([string]$_.userPrincipalName).ToLowerInvariant())) -or
        ($_.displayName -and $wanted.ContainsKey(([string]$_.displayName).ToLowerInvariant()))
    })
    $matched = @{}
    foreach ($agent in $selectedAgents) {
        $matched[([string]$agent.sam).ToLowerInvariant()] = $true
        if ($agent.userPrincipalName) { $matched[([string]$agent.userPrincipalName).ToLowerInvariant()] = $true }
        if ($agent.displayName) { $matched[([string]$agent.displayName).ToLowerInvariant()] = $true }
    }
    $unmatched = @($Agents | Where-Object { -not $matched.ContainsKey($_.ToLowerInvariant()) })
    if ($unmatched.Count -gt 0) {
        Write-Host "[WARN] Requested agent(s) not found in config: $($unmatched -join ', ')" -ForegroundColor Yellow
        Write-Host "       Add expansion users with .\tools\Add-StorylineAgents.ps1, then update Automation variables." -ForegroundColor Gray
    }
}
if (-not $selectedAgents -or $selectedAgents.Count -eq 0) { throw "No agents selected." }

Write-Host "=== Full Agent Run Test ===" -ForegroundColor Cyan
Write-Host "  Automation: $aaName ($rg)"
Write-Host "  Agents:     $($selectedAgents.Count)"
Write-Host "  Mode:       $(if ($Parallel) { "parallel (throttle=$ThrottleLimit)" } else { 'sequential' })"
Write-Host "  StartRetry: $MaxStartRetries x $StartRetrySeconds sec on Automation quota throttling"
Write-Host ""

$runStart = (Get-Date).ToUniversalTime().AddMinutes(-2)
$resultsBySam = @{}
$jobs = @()
foreach ($agent in $selectedAgents) {
    $result = New-AgentResult -Agent $agent
    $resultsBySam[$agent.sam] = $result
}

$serviceOverrides = @{}
$requestedServiceFilter = ''
if ($Services -and $Services.Count -gt 0) {
    $requestedServiceFilter = (($Services | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ',')
}

$aiRotation = @($AIServices | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($aiRotation.Count -eq 0) { $aiRotation = @('llama','claude','deepseek','grok') }
$aiIndex = 0
foreach ($agent in $selectedAgents) {
    if ($requestedServiceFilter) {
        $serviceOverrides[$agent.sam] = $requestedServiceFilter
    } elseif ([string]$agent.workload -eq 'ExternalAI') {
        $serviceOverrides[$agent.sam] = $aiRotation[$aiIndex % $aiRotation.Count]
        if ($agent.sam -eq 'devon.reyes') {
            $serviceOverrides[$agent.sam] = "$($serviceOverrides[$agent.sam]),irm"
        }
        $aiIndex++
    }
    if ($serviceOverrides.ContainsKey($agent.sam)) {
        $resultsBySam[$agent.sam].ServiceFilter = $serviceOverrides[$agent.sam]
    }
}

function Start-AgentJob {
    param(
        $Agent,
        [string]$SubId,
        [string]$ResourceGroup,
        [string]$AutomationAccount,
        [string]$ServiceFilter,
        [int]$RetrySeconds = 60,
        [int]$MaxRetries = 10
    )
    $parameters = @{
        ActivityMode = 'burst'
        SkipWeekendCheck = 'True'
        RunAsAgent = $Agent.sam
    }
    if (-not [string]::IsNullOrWhiteSpace($ServiceFilter)) {
        $parameters.ServiceFilter = $ServiceFilter
    }
    $body = @{
        properties = @{
            runbook = @{ name = 'Invoke-AgentRunbook' }
            parameters = $parameters
        }
    }

    for ($attempt = 1; $attempt -le ($MaxRetries + 1); $attempt++) {
        $headers = Get-AzHeaders
        $jobId = [string](New-Guid)
        try {
            Invoke-RestMethod -Method PUT `
                -Uri "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount/jobs/${jobId}?api-version=2023-11-01" `
                -Headers $headers -Body (ConvertTo-JsonBytes -Value $body -Depth 6) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            return $jobId
        }
        catch {
            $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            $isQuotaThrottle = $details -match '"code"\s*:\s*429|concurrent jobs|quota for concurrent jobs|TooManyRequests'
            if (-not $isQuotaThrottle -or $attempt -gt $MaxRetries) {
                throw
            }
            Write-Host "`n  [WAIT] Automation concurrent job quota reached while starting $($Agent.sam). Retry $attempt/$MaxRetries in $RetrySeconds sec..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetrySeconds
        }
    }
}

if ($Parallel) {
    $pending = [System.Collections.Queue]::new()
    foreach ($agent in $selectedAgents) { $pending.Enqueue($agent) }
    $running = @{}

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
            $agent = $pending.Dequeue()
            $filter = if ($serviceOverrides.ContainsKey($agent.sam)) { $serviceOverrides[$agent.sam] } else { '' }
            $filterLabel = if ($filter) { " [$filter]" } else { '' }
            Write-Host "Starting $($agent.sam)$filterLabel..." -NoNewline
            $jobId = Start-AgentJob -Agent $agent -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -ServiceFilter $filter -RetrySeconds $StartRetrySeconds -MaxRetries $MaxStartRetries
            $resultsBySam[$agent.sam].JobId = $jobId
            $resultsBySam[$agent.sam].JobStatus = 'Running'
            $running[$jobId] = $agent.sam
            Write-Host " $jobId" -ForegroundColor Green
        }

        Start-Sleep -Seconds $PollSeconds
        foreach ($jobId in @($running.Keys)) {
            $status = Get-JobStatus -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -JobId $jobId
            $sam = $running[$jobId]
            $resultsBySam[$sam].JobStatus = $status
            Write-Host "  ${sam}: $status" -ForegroundColor Gray
            if ($status -notin @('Running','New','Activating')) {
                $running.Remove($jobId)
            }
        }
    }
} else {
    foreach ($agent in $selectedAgents) {
        $filter = if ($serviceOverrides.ContainsKey($agent.sam)) { $serviceOverrides[$agent.sam] } else { '' }
        $filterLabel = if ($filter) { " [$filter]" } else { '' }
        Write-Host "Starting $($agent.sam)$filterLabel..." -NoNewline
        $jobId = Start-AgentJob -Agent $agent -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -ServiceFilter $filter -RetrySeconds $StartRetrySeconds -MaxRetries $MaxStartRetries
        $resultsBySam[$agent.sam].JobId = $jobId
        $resultsBySam[$agent.sam].JobStatus = 'Running'
        Write-Host " $jobId" -ForegroundColor Green

        do {
            Start-Sleep -Seconds $PollSeconds
            $status = Get-JobStatus -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -JobId $jobId
            $resultsBySam[$agent.sam].JobStatus = $status
            Write-Host "  $($agent.sam): $status" -ForegroundColor Gray
        } while ($status -in @('Running','New','Activating'))
    }
}

Write-Host ""
Write-Host "Collecting Automation job output..." -ForegroundColor Cyan
foreach ($agent in $selectedAgents) {
    $result = $resultsBySam[$agent.sam]
    if (-not $result.JobId) {
        $result.Status = 'failed'
        $result.Comments = 'Job did not start.'
        continue
    }

    $output = Get-JobOutput -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -JobId $result.JobId
    $streams = Get-JobStreams -SubId $subId -ResourceGroup $rg -AutomationAccount $aaName -JobId $result.JobId
    $warnings = @($streams | Where-Object { $_.properties.streamType -eq 'Warning' })
    $errors = @($streams | Where-Object { $_.properties.streamType -eq 'Error' })
    $result.Warnings = $warnings.Count
    $result.Errors = $errors.Count
    $adxWarning = $warnings | Where-Object { $_.properties.summary -match '\[ADX\]' } | Select-Object -First 1
    if ($adxWarning) {
        $result.Comments = (($adxWarning.properties.summary -replace '\s+', ' ').Trim())
    }

    if ($output -match '=== COMPLETE:\s*(\d+)\s*files uploaded,\s*(?:(\d+)\s*file operations,\s*)?(\d+)\s*emails \+\s*(\d+)\s*thread emails sent(?:,\s*(\d+)\s*external AI interactions)?(?:,\s*(\d+)\s*insider risk events)?') {
        $result.FilesOut = [int]$Matches[1]
        if ($Matches[2]) { $result.FileOpsOut = [int]$Matches[2] }
        $result.EmailsOut = [int]$Matches[3]
        $result.ThreadEmails = [int]$Matches[4]
        if ($Matches[5]) { $result.ExternalAIOut = [int]$Matches[5] }
        if ($Matches[6]) { $result.IRM = [int]$Matches[6] }
    }
    if ($output -match '\[AUTH\] ROPC token acquired') {
        if (-not $result.Comments) { $result.Comments = 'Auth OK' }
    }
    if ($output -match '\[EXTERNAL-AI\] Evidence uploaded:') {
        $result.CollabSite = [Math]::Max($result.CollabSite, 1)
    }
    if ($output -match 'ROPC failed' -or ($output -match '0 files uploaded,\s*(?:0 file operations,\s*)?0 emails' -and $result.ExternalAIOut -eq 0 -and $result.IRM -eq 0)) {
        $result.Status = 'failed'
        $result.Comments = 'Authentication failed or no activity generated.'
    }
}

if (-not $NoADXWait) {
    Write-Host ""
    Write-Host "Waiting $ADXWaitMinutes minute(s) for ADX ingestion..." -ForegroundColor Gray
    Start-Sleep -Seconds ([Math]::Max(0, $ADXWaitMinutes * 60))
}

Write-Host "Querying ADX..." -ForegroundColor Cyan
if ($config.adx -and $config.adx.enabled -eq $true) {
    $adxToken = az account get-access-token --resource "https://kusto.kusto.windows.net" --query accessToken -o tsv 2>$null
    $adxHeaders = @{ Authorization = "Bearer $adxToken"; 'Content-Type' = 'application/json' }
    $startIso = $runStart.ToString('o')
    $tableName = $config.adx.tableName
    $query = @"
table('$tableName')
| where TimeGenerated >= datetime($startIso)
| summarize Count=count() by
    AgentName=tostring(Event.AgentName),
    ActivityType=coalesce(tostring(Event.ActivityType), tostring(Event.Actividad), tostring(Event.Activity)),
    Service=tostring(Event.Service),
    RuntimeMode=tostring(Event.RuntimeMode),
    TargetPath=tostring(Event.TargetPath)
"@
    try {
        $body = @{ db = $config.adx.databaseName; csl = $query } | ConvertTo-Json -Compress
        $adxResult = Invoke-RestMethod -Method POST -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" -Headers $adxHeaders -Body $body -ErrorAction Stop
        foreach ($row in @($adxResult.Tables[0].Rows)) {
            $agentName = [string]$row[0]
            $activityType = [string]$row[1]
            $service = [string]$row[2]
            $runtimeMode = [string]$row[3]
            $targetPath = [string]$row[4]
            $count = [int]$row[5]
            $result = $resultsBySam.Values | Where-Object { $_.DisplayName -eq $agentName } | Select-Object -First 1
            if (-not $result) { continue }
            switch -Regex ($activityType) {
                '^email$' { $result.Email += $count; break }
                '^copilot$' { $result.Copilot += $count; break }
                '^sensitivity_label$' { $result.Labels += $count; break }
                '^activity_explorer$' { $result.FileOps += $count; break }
                '^external_ai$' {
                    $result.ExternalAI += $count
                    if ($runtimeMode -match 'RealFoundry') { $result.Foundry += $count }
                    elseif ($runtimeMode -match 'Simulated|Fallback') { $result.SimAI += $count }
                    if ($targetPath -and $targetPath -ne 'Unmapped collaboration team') { $result.CollabSite = [Math]::Max($result.CollabSite, $result.ExternalAI) }
                    if (-not $result.Comments -and $service) { $result.Comments = "AI: $service" }
                    break
                }
                '^insider_risk$' { $result.IRM += $count; break }
                '^Fabric$' { $result.Fabric += $count; $result.Upload += $count; break }
                '^Teams$' { $result.Teams += $count; $result.Upload += $count; break }
                '^Chat$' { $result.Chat += $count; $result.Upload += $count; break }
                '^Lists$' { $result.Lists += $count; $result.Upload += $count; break }
                '^Meetings$' { $result.Meetings += $count; $result.Upload += $count; break }
                default { $result.SPO += $count; $result.Upload += $count; break }
            }
        }
    } catch {
        $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "[WARN] ADX query failed: $msg" -ForegroundColor Yellow
        foreach ($result in $resultsBySam.Values) {
            if (-not $result.Comments) { $result.Comments = 'ADX query unavailable.' }
        }
    }
} else {
    Write-Host "[WARN] ADX telemetry is not configured." -ForegroundColor Yellow
}

foreach ($result in $resultsBySam.Values) {
    if ($result.ExternalAI -eq 0 -and $result.ExternalAIOut -gt 0) {
        $result.ExternalAI = $result.ExternalAIOut
    }
    if ($result.FileOps -eq 0 -and $result.FileOpsOut -gt 0) {
        $result.FileOps = $result.FileOpsOut
    }
    $activityTotal = $result.Upload + $result.FileOps + $result.Email + $result.Copilot + $result.Labels + $result.ExternalAI + $result.IRM + $result.ThreadEmails
    if ($result.JobStatus -notin @('Completed','Succeeded')) {
        $result.Status = 'failed'
        if (-not $result.Comments) { $result.Comments = "Automation job ended as $($result.JobStatus)." }
    } elseif ($result.Status -eq 'failed') {
        # keep explicit failure from output parsing
    } elseif ($activityTotal -gt 0 -or $result.FilesOut -gt 0 -or $result.EmailsOut -gt 0) {
        if ($result.Errors -gt 0) {
            $result.Status = 'partial'
            $result.Comments = "Completed with $($result.Errors) error stream item(s)."
        } elseif ($result.Warnings -gt 0) {
            $result.Status = 'partial'
            $result.Comments = "Completed with $($result.Warnings) warning(s)."
        } else {
            $result.Status = 'success'
            $result.Comments = 'Completed with activity.'
        }
    } else {
        $result.Status = 'partial'
        if (-not $result.Comments) { $result.Comments = 'Completed, but no activity was confirmed yet.' }
    }
}

$results = @($selectedAgents | ForEach-Object { $resultsBySam[$_.sam] })

Write-Host ""
Write-Host "=== Full Run Results ===" -ForegroundColor Green
$results |
    Select-Object User,Department,JobStatus,ServiceFilter,Upload,SPO,Fabric,Teams,Chat,Lists,Meetings,FileOps,Email,Copilot,ExternalAI,Foundry,SimAI,IRM,CollabSite,ThreadEmails,FilesOut,FileOpsOut,EmailsOut,ExternalAIOut,Warnings,Errors,Status,Comments |
    Format-Table -AutoSize

$summary = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ""
Write-Host "Summary: $($summary -join ', ')" -ForegroundColor Cyan



