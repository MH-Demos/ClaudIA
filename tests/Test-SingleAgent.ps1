<#
.SYNOPSIS
    Quick test: run a single agent and verify data in Azure Data Explorer.
.PARAMETER Agent
    SamAccountName of the agent to test (e.g., 'ana.rodriguez').
.PARAMETER Services
    Optional comma-separated services/workloads to force for the test.
    Supported values include: spo, sharepoint, mail, email, exchange, teams,
    chat, lists, fabric, meetings, fileops, activityexplorer, copilot,
    externalai, foundry, llama, claude, deepseek, grok, irm.
.PARAMETER Help
    Show usage and supported service aliases.
.EXAMPLE
    .\Test-SingleAgent.ps1 -Agent ana.rodriguez
.EXAMPLE
    .\Test-SingleAgent.ps1 -Agent devon.reyes -Services llama
.EXAMPLE
    .\Test-SingleAgent.ps1 -Agent devon.reyes -Services mail, Teams, Claude
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$Agent,
    [string[]]$Services = @(),
    [switch]$BrowserAgent,
    [string[]]$BrowserServices = @('owa','copilot'),
    [string]$ExternalRecipient = 'demo.recipient@example.com',
    [switch]$SendEmail,
    [switch]$Sensitive,
    [string]$Label = '',
    [switch]$SkipBrowserPreflight,
    [switch]$Help,
    [string]$ConfigPath = '',
    [string]$InstallationDefinitionsPath = ''
)

function Show-TestSingleAgentHelp {
    Write-Host "Test-SingleAgent.ps1" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor White
    Write-Host "  .\tests\Test-SingleAgent.ps1 -Agent devon.reyes"
    Write-Host "  .\tests\Test-SingleAgent.ps1 -Agent devon.reyes -Services llama"
    Write-Host "  .\tests\Test-SingleAgent.ps1 -Agent devon.reyes -Services mail, Teams, Claude"
    Write-Host "  .\tests\Test-SingleAgent.ps1 -Agent priya.sharma -BrowserAgent -BrowserServices owa,copilot"
    Write-Host "  .\tests\Test-SingleAgent.ps1 -Agent priya.sharma -BrowserAgent -BrowserServices owa -SendEmail -Sensitive -Label General"
    Write-Host ""
    Write-Host "Supported service aliases:" -ForegroundColor White
    Write-Host "  SharePoint files: spo, sharepoint, sharepoint online, files"
    Write-Host "  Mail:             mail, email, exchange, exchange online, outlook"
    Write-Host "  Teams:            teams, microsoft teams"
    Write-Host "  Teams chat:       chat"
    Write-Host "  Microsoft Lists:  lists, microsoft lists"
    Write-Host "  Fabric:           fabric, microsoft fabric"
    Write-Host "  Meetings:         meetings"
    Write-Host "  File operations:  fileops, activityexplorer, activity explorer, audit"
    Write-Host "  Copilot:          copilot, microsoft 365 copilot, m365 copilot"
    Write-Host "  External AI:      externalai, external ai, ai, foundry, azure ai foundry"
    Write-Host "  Foundry models:   llama, claude, deepseek, grok"
    Write-Host "  Insider Risk:     irm, insider risk, insider risk management, purview irm, risk, exfiltration"
    Write-Host ""
    Write-Host "Notes:" -ForegroundColor White
    Write-Host "  - The filter is passed to Invoke-AgentRunbook as ServiceFilter."
    Write-Host "  - Model names select the ExternalAI path and, when possible, the matching configured service."
    Write-Host "  - For real Foundry calls, configure externalAiRuntime.endpoint in config\agents.json and publish the runbook."
    Write-Host "  - Use -BrowserAgent to run real M365 web activity through BrowserAgents instead of Azure Automation."
}

if ($Help) {
    Show-TestSingleAgentHelp
    return
}

if ([string]::IsNullOrWhiteSpace($Agent)) {
    Write-Host "[ERROR] -Agent is required unless -Help is used." -ForegroundColor Red
    Show-TestSingleAgentHelp
    return
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot '..\config\agents.json'
}
if ([string]::IsNullOrWhiteSpace($InstallationDefinitionsPath)) {
    $InstallationDefinitionsPath = Join-Path $scriptRoot '..\config\Installation_definitions.json'
}

$serviceText = (($Services -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','
$knownServiceAliases = @(
    'spo','sharepoint','sharepoint online','files',
    'mail','email','exchange','exchange online','outlook',
    'teams','microsoft teams','chat',
    'lists','microsoft lists',
    'fabric','microsoft fabric',
    'meetings',
    'fileops','activityexplorer','activity explorer','audit',
    'copilot','microsoft 365 copilot','m365 copilot',
    'externalai','external ai','ai','foundry','azure ai foundry',
    'llama','claude','deepseek','grok',
    'irm','insider risk','insider risk management','purview irm','risk','exfiltration','exfiltrate'
)
if ($serviceText) {
    $unknown = @($serviceText -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -and $knownServiceAliases -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Host "[ERROR] Unknown service alias(es): $($unknown -join ', ')" -ForegroundColor Red
        Write-Host "Run .\tests\Test-SingleAgent.ps1 -Help to see supported values." -ForegroundColor Yellow
        return
    }

    $normalizedServices = @($serviceText -split ',' | ForEach-Object {
        $item = $_.Trim()
        switch ($item.ToLowerInvariant()) {
            'activityexplorer' { 'fileops'; break }
            'activity explorer' { 'fileops'; break }
            'audit' { 'fileops'; break }
            default { $item; break }
        }
    } | Where-Object { $_ })
    $serviceText = ($normalizedServices | Select-Object -Unique) -join ','
}

. (Join-Path $scriptRoot '..\modules\Common.ps1')
$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config
$agentInfo = $config.agents | Where-Object { $_.sam -eq $Agent }
if (-not $agentInfo) { Write-Host "[ERROR] Agent '$Agent' not found in config." -ForegroundColor Red; return }

Write-Host "=== Testing $($agentInfo.displayName) ($($agentInfo.department)) ===" -ForegroundColor Cyan
if ($serviceText) {
    Write-Host "Service filter: $serviceText" -ForegroundColor Cyan
}

if ($BrowserAgent) {
    $repoRoot = Resolve-Path (Join-Path $scriptRoot '..')
    $browserServicesText = (($BrowserServices -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','
    if (-not $browserServicesText) { $browserServicesText = 'owa,copilot' }

    Write-Host "BrowserAgent services: $browserServicesText" -ForegroundColor Cyan
    if (-not $SkipBrowserPreflight) {
        & (Join-Path $repoRoot 'tools\Initialize-BrowserAgents.ps1') `
            -Agents $Agent `
            -Services $browserServicesText `
            -SkipAuth `
            -ContinueOnFailure `
            -ConfigPath $ConfigPath
        if ($LASTEXITCODE -ne 0) { throw "BrowserAgent initialization failed." }
    }

    $dailyArgs = @{
        Agent = $Agent
        Services = @($browserServicesText -split ',')
        ConfigPath = $ConfigPath
    }
    if ($ExternalRecipient) { $dailyArgs.ExternalRecipient = $ExternalRecipient }
    if ($SendEmail) { $dailyArgs.SendEmail = $true }
    if ($Sensitive) { $dailyArgs.Sensitive = $true }
    if ($Label) { $dailyArgs.Label = $Label }

    & (Join-Path $repoRoot 'tools\Invoke-BrowserAgentDaily.ps1') @dailyArgs
    if ($LASTEXITCODE -ne 0) { throw "BrowserAgent daily activity failed." }

    Write-Host "`nWaiting 30 sec for ADX ingestion..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
    & (Join-Path $repoRoot 'tools\Get-BrowserAgentTelemetry.ps1') -Agent $Agent -SinceMinutes 60 -ConfigPath $ConfigPath
    return
}

# Start Automation job for this agent
$t = az account get-access-token --query accessToken -o tsv 2>$null
$h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}
$aaName = $config.infrastructure.automationAccountName
$rg = $config.infrastructure.resourceGroup
$subId = $config.tenant.subscriptionId
az account set -s $subId 2>$null

# Automation may exist in a different RG when reusing definitions.
$aaExists = az automation account show -n $aaName -g $rg --query name -o tsv 2>$null
if (-not $aaExists) {
    $aaRg = az automation account list --query "[?name=='$aaName'].resourceGroup | [0]" -o tsv 2>$null
    if ($aaRg) {
        Write-Host "[INFO] Automation '$aaName' found in resource group '$aaRg'." -ForegroundColor DarkYellow
        $rg = $aaRg
    }
}

# Warn when the published Automation runbook is stale relative to recent JSON body fixes.
try {
    $runbookContentUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/Invoke-AgentRunbook/content?api-version=2023-11-01"
    $publishedRunbook = Invoke-RestMethod -Uri $runbookContentUri -Headers $h -ErrorAction Stop
    if ($publishedRunbook -notmatch 'return ,\(\[System\.Text\.Encoding\]::UTF8\.GetBytes\(\$json\)\)' -or
        $publishedRunbook -notmatch 'ServiceFilter' -or
        $publishedRunbook -notmatch 'Invoke-ActivityExplorerFileSignals' -or
        $publishedRunbook -notmatch 'insider risk events') {
        Write-Host "[WARN] Published runbook may be stale. Run .\tools\Publish-RunbookOnly.ps1 before testing." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] Could not verify published runbook content: $($_.Exception.Message)" -ForegroundColor Yellow
}

$jobParameters = @{
    ActivityMode = 'burst'
    SkipWeekendCheck = 'True'
    RunAsAgent = $Agent
}
if ($serviceText) {
    $jobParameters.ServiceFilter = $serviceText
}
$jBody = @{properties=@{runbook=@{name='Invoke-AgentRunbook'};parameters=$jobParameters}} | ConvertTo-Json -Depth 4
$j = Invoke-RestMethod -Method PUT `
    -Uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/jobs/$(New-Guid)?api-version=2023-11-01" `
    -Headers $h -Body $jBody
Write-Host "Job started: $($j.name)" -ForegroundColor Green

# Poll every 60s
do {
    Start-Sleep 60
    $t = az account get-access-token --query accessToken -o tsv 2>$null
    $h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}
    $st = (Invoke-RestMethod "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/jobs/$($j.name)?api-version=2023-11-01" -Headers $h).properties.status
    Write-Host "  Status: $st" -ForegroundColor Gray
} while ($st -eq 'Running' -or $st -eq 'New' -or $st -eq 'Activating')

# Get output
$output = Invoke-RestMethod "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/jobs/$($j.name)/output?api-version=2023-11-01" -Headers $h
$output -split "`n" | Where-Object { $_ -match 'AUTH|KV|Uploaded|Teams|Fabric|File read|File downloaded|Upload text|File modified|File renamed|File deleted|COPILOT|EXTERNAL-AI|IRM|DONE|COMPLETE' } | ForEach-Object { Write-Host "  $_" }

# Get warning/error streams. The output endpoint does not include all useful diagnostics.
$streamsUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName/jobs/$($j.name)/streams?api-version=2023-11-01"
$streams = @()
try {
    $streams = @((Invoke-RestMethod $streamsUri -Headers $h).value)
} catch {
    Write-Host "  [WARN] Could not fetch job streams: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($streams.Count -gt 0) {
    $interesting = $streams | Where-Object {
        $_.properties.streamType -in @('Error','Warning') -or
        $_.properties.summary -match 'AUTH|KV|PLAN|ADX|Key Vault|secret|Graph|SPO|Upload|File read|File downloaded|Upload text|File modified|File renamed|File deleted|EXTERNAL-AI|IRM|Foundry|failed|Failed|Exception|COMPLETE'
    }
    if ($interesting.Count -gt 0) {
        Write-Host "`n=== Job Diagnostics ===" -ForegroundColor Cyan
        foreach ($s in $interesting) {
            $type = $s.properties.streamType
            $summary = $s.properties.summary
            if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
            $color = if ($type -eq 'Error') { 'Red' } elseif ($type -eq 'Warning') { 'Yellow' } else { 'Gray' }
            Write-Host "  [$type] $summary" -ForegroundColor $color
        }
    }
}

if ($output -match '=== COMPLETE: 0 files uploaded,\s*(?:0 file operations,\s*)?0 emails' -and
    $output -notmatch '\[EXTERNAL-AI\]' -and
    $output -notmatch '[1-9][0-9]* external AI interactions' -and
    $output -notmatch '[1-9][0-9]* insider risk events' -and
    $output -notmatch '\+ [1-9][0-9]* thread emails sent') {
    Write-Host "`n[WARN] The runbook completed but generated no activity. Review Job Diagnostics above before waiting on ADX." -ForegroundColor Yellow
    return
}

# Check ADX (streaming ingestion is near-real-time, but give it a short buffer)
Write-Host "`nWaiting 60 sec for ADX ingestion..." -ForegroundColor Gray
Start-Sleep 60
if (-not $config.adx -or $config.adx.enabled -ne $true) {
    Write-Host "`n[WARN] ADX telemetry is not configured in Installation_definitions.json." -ForegroundColor Yellow
    return
}

$adxToken = az account get-access-token --resource "https://kusto.kusto.windows.net" --query accessToken -o tsv 2>$null
$adxh = @{Authorization="Bearer $adxToken"; 'Content-Type'='application/json'}
$tableName = $config.adx.tableName
$displayName = $agentInfo.displayName.Replace("'", "''")
$serviceFilterKql = ''
if ($serviceText) {
    $serviceTerms = [System.Collections.Generic.List[string]]::new()
    $includeActivityExplorerTarget = $false
    foreach ($term in @($serviceText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $serviceTerms.Add($term) | Out-Null
        switch ($term.ToLowerInvariant()) {
            'fileops' {
                $includeActivityExplorerTarget = $true
                @(
                    'activity_explorer',
                    'ActivityExplorerTarget',
                    'FileRead',
                    'DownloadFile',
                    'UploadText',
                    'FileCreated',
                    'FileModified',
                    'FileRenamed',
                    'FileDeleted',
                    'SharePoint Online',
                    'SPO'
                ) | ForEach-Object { $serviceTerms.Add($_) | Out-Null }
                break
            }
        }
    }
    $serviceValues = ($serviceTerms | Select-Object -Unique | ForEach-Object { $_.Replace("'", "''") }) -join "','"
    $activityExplorerClause = if ($includeActivityExplorerTarget) { " or tobool(Event.ActivityExplorerTarget) == true" } else { '' }
    $serviceFilterKql = "| where tostring(Event.Service) has_any ('$serviceValues') or tostring(Event.ActivityType) has_any ('$serviceValues') or tostring(Event.Action) has_any ('$serviceValues') or tostring(Event.ModelFamily) has_any ('$serviceValues') or tostring(Event.Provider) has_any ('$serviceValues') or tostring(Event.Detail) has_any ('$serviceValues') or tostring(Event.IRMScenario) has_any ('$serviceValues') or tostring(Event.IRMIndicator) has_any ('$serviceValues')$activityExplorerClause"
}
$kql = @"
table('$tableName')
| where tostring(Event.AgentName) == '$displayName'
| where TimeGenerated > ago(30m)
$serviceFilterKql
| summarize Count=count() by ActivityType=tostring(Event.ActivityType)
"@
$q = @{ db = $config.adx.databaseName; csl = $kql } | ConvertTo-Json
$r = $null
try {
    $r = Invoke-RestMethod -Method POST -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" -Headers $adxh -Body $q -ErrorAction Stop
} catch {
    $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    if ($msg -match 'does not refer to any known table|Failed to resolve|EntityNotFound') {
        Write-Host "`n[WARN] ADX table '$tableName' does not exist yet. Run tools\Deploy-AdxTelemetry.ps1." -ForegroundColor Yellow
        return
    }
    throw
}

if ($r -and $r.Tables -and $r.Tables[0].Rows.Count -gt 0) {
    Write-Host "`n=== ADX Data ===" -ForegroundColor Green
    $r.Tables[0].Rows | ForEach-Object { Write-Host "  $($_[0]): $($_[1])" }
    Write-Host "`n[PASS] Agent telemetry verified in Azure Data Explorer." -ForegroundColor Green
} else {
    Write-Host "`n[WARN] No data in ADX yet. May need more time or runbook diagnostics review." -ForegroundColor Yellow
}

