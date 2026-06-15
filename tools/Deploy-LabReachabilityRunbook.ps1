<#PSScriptInfo

.VERSION 1.0.0

.GUID 4b8d6c1a-3e9f-4a7d-9c2b-8e1f5d3a7c0b

.AUTHOR
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Azure MCAPS Hardening Runbook

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Deploy Restore-LabPublicNetworkAccess.ps1 as an Azure Automation runbook with
a daily 06:00 UTC schedule. Use this in MCAPS / Microsoft Managed Environment
/ hardened test tenants so the lab survives nightly Azure Policy hardening.
#>

<#
.SYNOPSIS
    Upload Restore-LabPublicNetworkAccess.ps1 to the ClaudIA Automation Account
    and schedule it to run daily.

.DESCRIPTION
    Creates an Azure Automation runbook named 'Restore-LabPublicNetworkAccess'
    in the ClaudIA Automation Account, publishes it, attaches a daily 06:00 UTC
    schedule, grants the Automation Account's system-assigned managed identity
    Contributor on the resource group (so the runbook can PATCH PNA + start
    ADX), and links the schedule with -UseAutomationManagedIdentity:$true.

    Requires: 'az' CLI logged in to the same subscription as the lab, and the
    operator must hold Owner or User Access Administrator on the resource group
    (the script grants Contributor to the AA managed identity).

.PARAMETER ResourceGroup
    Resource group holding the ClaudIA resources (e.g. rg-claudia-lab).

.PARAMETER AutomationAccountName
    Optional. Defaults to Installation_definitions.json -> infrastructure.automationAccountName.

.PARAMETER ScheduleTime
    Optional. UTC time-of-day for the daily schedule. Default: 06:00.

.PARAMETER InstallationDefinitionsPath
    Path to Installation_definitions.json. Defaults to ../config/.

.EXAMPLE
    .\Deploy-LabReachabilityRunbook.ps1 -ResourceGroup rg-claudia-lab
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$AutomationAccountName,
    [string]$ScheduleTime = '06:00',
    [string]$InstallationDefinitionsPath
)

$ErrorActionPreference = 'Stop'

if (-not $InstallationDefinitionsPath) {
    $InstallationDefinitionsPath = Join-Path $PSScriptRoot '..\config\Installation_definitions.json'
}
$defs = Get-Content $InstallationDefinitionsPath -Raw | ConvertFrom-Json
if (-not $AutomationAccountName) { $AutomationAccountName = $defs.infrastructure.automationAccountName }
if (-not $AutomationAccountName) { throw "AutomationAccountName not provided and not found in Installation_definitions.json." }

$runbookSource = Join-Path $PSScriptRoot 'Restore-LabPublicNetworkAccess.ps1'
if (-not (Test-Path $runbookSource)) { throw "Source runbook not found: $runbookSource" }

$runbookName = 'Restore-LabPublicNetworkAccess'
$scheduleName = 'Daily-Reachability-Restore'

Write-Host "Deploying ClaudIA daily reachability runbook" -ForegroundColor Cyan
Write-Host "  Automation Account: $AutomationAccountName"
Write-Host "  Resource group:     $ResourceGroup"
Write-Host "  Schedule:           daily at $ScheduleTime UTC"
Write-Host ""

$sub = az account show --query id -o tsv

# 1. Grant AA managed identity Contributor on the RG (idempotent)
$aaMi = az automation account show -n $AutomationAccountName -g $ResourceGroup --query identity.principalId -o tsv 2>$null
if (-not $aaMi) { throw "Automation Account '$AutomationAccountName' has no system-assigned managed identity. Enable it first." }
Write-Host "  Granting Contributor on '$ResourceGroup' to Automation MI..." -NoNewline
az role assignment create --role Contributor --assignee-object-id $aaMi --assignee-principal-type ServicePrincipal `
    --scope "/subscriptions/$sub/resourceGroups/$ResourceGroup" -o none 2>$null
Write-Host " [OK]" -ForegroundColor Green

# 2. Create or update the runbook via ARM REST (PowerShell72 runtime, matching the
#    agent runbook). The 'az automation runbook' CLI is experimental and older
#    versions reject --type PowerShell72 outright; worse, those failures are silent
#    when piped to -o none, which would leave the schedule pointing at a missing
#    runbook. PUT/POST directly to ARM and check every response so we fail loudly.
Write-Host "  Uploading runbook '$runbookName' (PowerShell72)..." -NoNewline
$location = az group show -n $ResourceGroup --query location -o tsv
$token = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
if (-not $token) { Write-Host " [FAIL]" -ForegroundColor Red; throw "Could not acquire an Azure management access token." }
$jsonHeaders = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$aaUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"

$rbBody = @{ location = $location; properties = @{ runbookType = 'PowerShell72'; logProgress = $false; logVerbose = $false; description = 'ClaudIA - daily reachability restore (MCAPS hardened-tenant fallback)' } } | ConvertTo-Json -Depth 3
try {
    Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/$runbookName?api-version=2023-11-01" -Headers $jsonHeaders -Body $rbBody -ErrorAction Stop | Out-Null
} catch {
    # Metadata create-PUT returns 400 when the runbook already exists (and 409 on
    # some API versions). Either way it is non-fatal: the draft/content PUT + publish
    # below is the real gate -- it 404s only if the runbook genuinely does not exist.
}

$uploaded = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/$runbookName/draft/content?api-version=2023-11-01" `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'text/powershell' } `
            -Body ([System.IO.File]::ReadAllBytes($runbookSource)) -ErrorAction Stop | Out-Null
        Invoke-RestMethod -Method POST -Uri "$aaUri/runbooks/$runbookName/publish?api-version=2023-11-01" `
            -Headers $jsonHeaders -ErrorAction Stop | Out-Null
        $uploaded = $true
        break
    } catch {
        if ($attempt -lt 3) {
            Write-Host " [retry $attempt/3]" -ForegroundColor DarkYellow -NoNewline
            Start-Sleep -Seconds (15 * $attempt)
        } else {
            Write-Host " [FAIL]" -ForegroundColor Red
            throw "Runbook content upload/publish failed for '$runbookName': $($_.Exception.Message)"
        }
    }
}
Write-Host " [OK]" -ForegroundColor Green

# 3. Create or update the daily schedule (start tomorrow at ScheduleTime UTC)
Write-Host "  Creating daily schedule '$scheduleName' at $ScheduleTime UTC..." -NoNewline
$startTime = ([datetime]::UtcNow.Date.AddDays(1).Add([timespan]$ScheduleTime)).ToString('o')
$scheduleExists = az automation schedule show --automation-account-name $AutomationAccountName -g $ResourceGroup `
    --name $scheduleName --query name -o tsv 2>$null
if (-not $scheduleExists) {
    az automation schedule create --automation-account-name $AutomationAccountName -g $ResourceGroup `
        --name $scheduleName --frequency Day --interval 1 --start-time $startTime --time-zone UTC -o none
}
Write-Host " [OK]" -ForegroundColor Green

# 4. Link schedule to runbook with parameters (ARM REST, deduplicated). jobSchedules
#    are keyed by GUID, so re-linking on every rerun would stack duplicate daily runs.
Write-Host "  Linking schedule to runbook with parameters..." -NoNewline
$existingLinks = @()
try {
    $existingLinks = @((Invoke-RestMethod -Method GET -Uri "$aaUri/jobSchedules?api-version=2023-11-01" -Headers $jsonHeaders -ErrorAction Stop).value)
} catch { }
$alreadyLinked = $existingLinks | Where-Object {
    $_.properties.runbook.name -eq $runbookName -and $_.properties.schedule.name -eq $scheduleName
} | Select-Object -First 1
if ($alreadyLinked) {
    $linkDetails = Invoke-RestMethod -Method GET -Uri "$aaUri/jobSchedules/$($alreadyLinked.name)?api-version=2023-11-01" -Headers $jsonHeaders -ErrorAction SilentlyContinue
    $linkParams = $linkDetails.properties.parameters
    $rgMatches = ($linkParams -and [string]$linkParams.ResourceGroup -eq $ResourceGroup)
    $miValue = if ($linkParams) { [string]$linkParams.UseAutomationManagedIdentity } else { '' }
    $miMatches = ($miValue -eq 'True' -or $miValue -eq 'true' -or $miValue -eq '1')

    if ($rgMatches -and $miMatches) {
        Write-Host " [OK] already linked" -ForegroundColor Green
    } else {
        az automation job-schedule delete --automation-account-name $AutomationAccountName -g $ResourceGroup --job-schedule-id $($alreadyLinked.name) -o none 2>$null
        $alreadyLinked = $null
    }
}
if (-not $alreadyLinked) {
    $linkBody = @{ properties = @{ runbook = @{ name = $runbookName }; schedule = @{ name = $scheduleName }; parameters = @{ ResourceGroup = $ResourceGroup; UseAutomationManagedIdentity = $true } } } | ConvertTo-Json -Depth 4
    try {
        Invoke-RestMethod -Method PUT -Uri "$aaUri/jobSchedules/$(New-Guid)?api-version=2023-11-01" -Headers $jsonHeaders -Body $linkBody -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FAIL] link: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

$paramsJson = @{
    ResourceGroup = $ResourceGroup
    UseAutomationManagedIdentity = $true
} | ConvertTo-Json -Compress

Write-Host ""
Write-Host "Done. The runbook will run daily at $ScheduleTime UTC starting $startTime." -ForegroundColor Green
Write-Host "To run it once manually now:" -ForegroundColor Cyan
Write-Host "  az automation runbook start --automation-account-name $AutomationAccountName -g $ResourceGroup --name $runbookName --parameters '$paramsJson'"
Write-Host ""
