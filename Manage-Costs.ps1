<#
.SYNOPSIS
    Cost management utilities for the ClaudIA lab.
.DESCRIPTION
    Check current Azure spend, estimate monthly costs, pause/resume Fabric,
    adjust schedules, and get optimization recommendations.
.PARAMETER Action
    The cost management action:
      Status          - Show live Azure spend + resource state from Cost Management API.
      Estimate        - Project monthly cost based on current agents.json config.
      PauseFabric     - Suspend Fabric F2 capacity (saves ~$262/month).
      ResumeFabric    - Resume Fabric F2 capacity.
      ReduceSchedule  - Disable midday + afternoon schedules (keep morning only, ~40% savings).
      FullSchedule    - Re-enable all 3 daily schedules.
      Recommendations - Context-aware optimization advice based on current state.
.PARAMETER ConfigPath
    Path to agents.json configuration file.
.EXAMPLE
    .\Manage-Costs.ps1 -Action Status
    .\Manage-Costs.ps1 -Action PauseFabric
    .\Manage-Costs.ps1 -Action Recommendations

    === COST LEVERS (what you can control) ===

    1. AGENT COUNT: Edit agents.json to reduce from 10 to 5 (Wave 1 only).
       Impact: ~50% reduction in OpenAI tokens and Automation runtime.

    2. SCHEDULE FREQUENCY: Use ReduceSchedule action (3x/day -> 1x/day).
       Impact: ~66% reduction in Automation + OpenAI costs.

    3. FABRIC CAPACITY: Use PauseFabric action when not demoing.
       Impact: Saves $262/month (largest single cost item).

    4. OPENAI MODEL: Change infrastructure.openAiModel in agents.json.
       GPT-4o-mini ($0.15/1M tokens) vs GPT-4o ($2.50/1M tokens).

    5. FILE FREQUENCY: Reduce filesPerDay/emailsPerDay per agent in agents.json.
       Impact: Fewer OpenAI calls per run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Status','Estimate','PauseFabric','ResumeFabric','ReduceSchedule','FullSchedule','Recommendations')]
    [string]$Action,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\agents.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    Write-Host "[ERROR] Config not found: $ConfigPath" -ForegroundColor Red
    return
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$sub    = $config.tenant.subscriptionId
$rg     = $config.infrastructure.resourceGroup
$loc    = $config.tenant.location

# Ensure correct subscription
az account set -s $sub 2>$null

# =============================================================================
# STATUS - Show current resource state + cost data from Azure Cost Management
# =============================================================================
function Show-Status {
    Write-Host ""
    Write-Host "=== Agent Lab Cost Status ===" -ForegroundColor Cyan
    Write-Host ""

    # Resource existence check
    $aaName  = $config.infrastructure.automationAccountName
    $oaiName = $config.infrastructure.openAiAccountName
    Write-Host "  Resource Group: $rg" -ForegroundColor Gray
    $resources = az resource list -g $rg --query "[].{name:name,type:type,sku:sku.name}" -o json 2>$null | ConvertFrom-Json
    if (-not $resources) {
        Write-Host "  [WARN] Resource group not found or empty" -ForegroundColor Yellow
        return
    }

    foreach ($r in $resources) {
        $typeShort = ($r.type -split '/')[-1]
        $skuInfo = if ($r.sku) { " ($($r.sku))" } else { '' }
        Write-Host "    $($r.name) [$typeShort]$skuInfo" -ForegroundColor White
    }

    # Automation account state
    Write-Host ""
    $aaInfo = az automation account show -n $aaName -g $rg --query "{state:state,sku:sku.name}" -o json 2>$null | ConvertFrom-Json
    if ($aaInfo) {
        Write-Host "  Automation: $($aaInfo.state) ($($aaInfo.sku))" -ForegroundColor White
    }

    # Active schedules
    $schedules = az automation schedule list --automation-account-name $aaName -g $rg --query "[?isEnabled].name" -o json 2>$null | ConvertFrom-Json
    Write-Host "  Active schedules: $($schedules.Count)" -ForegroundColor White
    foreach ($s in $schedules) {
        Write-Host "    - $s" -ForegroundColor Gray
    }

    # Fabric capacity (if configured)
    if ($config.infrastructure.fabricEnabled) {
        Write-Host ""
        $fabCaps = az resource list --resource-type 'Microsoft.Fabric/capacities' --query "[?resourceGroup=='$rg'].{name:name,sku:sku.name}" -o json 2>$null | ConvertFrom-Json
        if ($fabCaps) {
            foreach ($f in $fabCaps) {
                $fabState = az resource show --ids "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Fabric/capacities/$($f.name)" --query "properties.state" -o tsv 2>$null
                $stateColor = if ($fabState -eq 'Active') { 'Green' } else { 'DarkYellow' }
                Write-Host "  Fabric: $($f.name) ($($f.sku)) - $fabState" -ForegroundColor $stateColor
            }
        } else {
            Write-Host "  Fabric: not deployed" -ForegroundColor Gray
        }
    }

    # Current month cost from Azure Cost Management
    Write-Host ""
    $startDate = (Get-Date -Day 1).ToString('yyyy-MM-dd')
    $endDate   = (Get-Date).ToString('yyyy-MM-dd')
    try {
        $costBody = @{
            type = 'ActualCost'
            timeframe = 'Custom'
            timePeriod = @{ from = $startDate; to = $endDate }
            dataset = @{
                granularity = 'None'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                filter = @{
                    dimensions = @{ name = 'ResourceGroup'; operator = 'In'; values = @($rg) }
                }
            }
        } | ConvertTo-Json -Depth 6
        $costUri = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        $token = az account get-access-token --query accessToken -o tsv 2>$null
        $costResult = Invoke-RestMethod -Method POST -Uri $costUri -Headers @{Authorization="Bearer $token";'Content-Type'='application/json'} -Body $costBody -ErrorAction Stop
        $totalCost = if ($costResult.properties.rows.Count -gt 0) { [math]::Round($costResult.properties.rows[0][0], 2) } else { 0 }
        $currency  = if ($costResult.properties.rows.Count -gt 0) { $costResult.properties.rows[0][1] } else { 'USD' }
        Write-Host "  Current month spend (RG): $totalCost $currency" -ForegroundColor $(if ($totalCost -gt 50) { 'Red' } elseif ($totalCost -gt 20) { 'Yellow' } else { 'Green' })
    } catch {
        Write-Host "  [WARN] Could not query Cost Management (needs Cost Management Reader role)" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# =============================================================================
# ESTIMATE - Project monthly cost based on current config
# =============================================================================
function Show-Estimate {
    Write-Host ""
    Write-Host "=== Monthly Cost Estimate ===" -ForegroundColor Cyan
    Write-Host ""

    $agentCount  = $config.agents.Count
    $schedCount  = $config.schedules.Count
    $fabEnabled  = [bool]$config.infrastructure.fabricEnabled

    # Automation: $0.002/min, ~20 min per run
    $aaMinPerMonth = $schedCount * 20 * 30
    $aaCost = [math]::Round($aaMinPerMonth * 0.002, 2)

    # OpenAI: ~5K tokens per agent per run at $0.15/1M input
    $tokensPerMonth = $agentCount * $schedCount * 30 * 5000
    $oaiCost = [math]::Round(($tokensPerMonth / 1000000) * 0.15, 2)

    # Fabric F2
    $fabCost = if ($fabEnabled) { 262 } else { 0 }

    $total = $aaCost + $oaiCost + $fabCost

    Write-Host "  Configuration:" -ForegroundColor Gray
    Write-Host "    Agents:    $agentCount" -ForegroundColor White
    Write-Host "    Schedules: $($schedCount)x/day" -ForegroundColor White
    Write-Host "    Fabric:    $(if ($fabEnabled) { 'Enabled' } else { 'Disabled' })" -ForegroundColor White
    Write-Host ""
    Write-Host "  Estimated Monthly Costs:" -ForegroundColor Gray
    Write-Host "    Automation (Basic):  `$$aaCost  ($aaMinPerMonth min)" -ForegroundColor White
    Write-Host "    Azure OpenAI:        `$$oaiCost  ($([math]::Round($tokensPerMonth/1000000, 1))M tokens)" -ForegroundColor White
    if ($fabEnabled) {
        Write-Host "    Fabric F2:           `$$fabCost" -ForegroundColor Yellow
    }
    Write-Host "    ----------------------------------------" -ForegroundColor Gray
    Write-Host "    TOTAL:               `$$total/month" -ForegroundColor $(if ($total -gt 50) { 'Yellow' } else { 'Green' })
    Write-Host ""

    if ($fabEnabled) {
        Write-Host "  TIP: Pause Fabric when not demoing: .\Manage-Costs.ps1 -Action PauseFabric" -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# =============================================================================
# PAUSE / RESUME FABRIC
# =============================================================================
function Set-FabricState([bool]$Resume) {
    $action = if ($Resume) { 'resume' } else { 'suspend' }
    $verb   = if ($Resume) { 'Resuming' } else { 'Pausing' }

    $fabCaps = az resource list -g $rg --resource-type 'Microsoft.Fabric/capacities' --query "[].name" -o json 2>$null | ConvertFrom-Json
    if (-not $fabCaps -or $fabCaps.Count -eq 0) {
        Write-Host "  [WARN] No Fabric capacity found in $rg" -ForegroundColor Yellow
        return
    }
    foreach ($cap in $fabCaps) {
        Write-Host "  $verb Fabric capacity: $cap..." -NoNewline
        $capId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Fabric/capacities/$cap"
        $token = az account get-access-token --query accessToken -o tsv 2>$null
        try {
            Invoke-RestMethod -Method POST -Uri "https://management.azure.com${capId}/${action}?api-version=2023-11-01" `
                -Headers @{Authorization="Bearer $token";'Content-Type'='application/json'} -ErrorAction Stop | Out-Null
            Write-Host " [OK]" -ForegroundColor Green
        } catch {
            Write-Host " [FAILED] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $saved = if (-not $Resume) { "Saving ~`$262/month while paused." } else { "Fabric is now billable (~`$262/month)." }
    Write-Host "  $saved" -ForegroundColor $(if ($Resume) { 'Yellow' } else { 'Green' })
    Write-Host ""
}

# =============================================================================
# SCHEDULE MANAGEMENT - reduce to 1x/day or restore 3x/day
# =============================================================================
function Set-ScheduleMode([bool]$Full) {
    $aaName = $config.infrastructure.automationAccountName
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    $h = @{Authorization="Bearer $token";'Content-Type'='application/json'}
    $aaUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aaName"

    $schedules = az automation schedule list --automation-account-name $aaName -g $rg --query "[].{name:name,isEnabled:isEnabled}" -o json 2>$null | ConvertFrom-Json

    if ($Full) {
        Write-Host "  Enabling all schedules (3x/day)..." -ForegroundColor Cyan
        foreach ($s in $schedules) {
            $body = @{properties=@{isEnabled=$true}} | ConvertTo-Json
            Invoke-RestMethod -Method PATCH -Uri "$aaUri/schedules/$($s.name)?api-version=2023-11-01" -Headers $h -Body $body | Out-Null
            Write-Host "    $($s.name): enabled" -ForegroundColor Green
        }
    } else {
        Write-Host "  Reducing to 1x/day (keeping morning only)..." -ForegroundColor Cyan
        foreach ($s in $schedules) {
            $enable = $s.name -match 'morning'
            $body = @{properties=@{isEnabled=$enable}} | ConvertTo-Json
            Invoke-RestMethod -Method PATCH -Uri "$aaUri/schedules/$($s.name)?api-version=2023-11-01" -Headers $h -Body $body | Out-Null
            $status = if ($enable) { 'enabled' } else { 'disabled' }
            $color  = if ($enable) { 'Green' } else { 'DarkYellow' }
            Write-Host "    $($s.name): $status" -ForegroundColor $color
        }
        Write-Host "  Estimated savings: ~40% on Automation + OpenAI costs" -ForegroundColor Green
    }
    Write-Host ""
}

# =============================================================================
# RECOMMENDATIONS - context-aware cost advice
# =============================================================================
function Show-Recommendations {
    Write-Host ""
    Write-Host "=== Cost Optimization Recommendations ===" -ForegroundColor Cyan
    Write-Host ""

    $recs = @()

    # Check Fabric
    if ($config.infrastructure.fabricEnabled) {
        $fabCaps = az resource list -g $rg --resource-type 'Microsoft.Fabric/capacities' --query "[].name" -o json 2>$null | ConvertFrom-Json
        if ($fabCaps) {
            foreach ($cap in $fabCaps) {
                $fabState = az resource show --ids "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Fabric/capacities/$cap" --query "properties.state" -o tsv 2>$null
                if ($fabState -eq 'Active') {
                    $recs += @{ Severity='HIGH'; Saving='$262/mo'; Action="Pause Fabric capacity '$cap' when not demoing: .\Manage-Costs.ps1 -Action PauseFabric" }
                }
            }
        }
    }

    # Check schedule count
    $aaName = $config.infrastructure.automationAccountName
    $activeScheds = az automation schedule list --automation-account-name $aaName -g $rg --query "[?isEnabled].name" -o json 2>$null | ConvertFrom-Json
    if ($activeScheds.Count -gt 1) {
        $recs += @{ Severity='MEDIUM'; Saving='~$2/mo'; Action="Reduce to 1x/day schedule: .\Manage-Costs.ps1 -Action ReduceSchedule" }
    }

    # Check agent count
    if ($config.agents.Count -gt 5) {
        $recs += @{ Severity='LOW'; Saving='~$1/mo'; Action="Reduce to 5 agents (Wave 1 only) in agents.json for minimal demo" }
    }

    if ($recs.Count -eq 0) {
        Write-Host "  No recommendations -- your configuration is already cost-optimized!" -ForegroundColor Green
    } else {
        foreach ($r in $recs) {
            $sevColor = switch ($r.Severity) { 'HIGH' { 'Red' } 'MEDIUM' { 'Yellow' } 'LOW' { 'DarkYellow' } default { 'Gray' } }
            Write-Host "  [$($r.Severity)] Save $($r.Saving)" -ForegroundColor $sevColor
            Write-Host "    $($r.Action)" -ForegroundColor White
            Write-Host ""
        }
    }
}

# =============================================================================
# DISPATCH
# =============================================================================
switch ($Action) {
    'Status'          { Show-Status }
    'Estimate'        { Show-Estimate }
    'PauseFabric'     { Set-FabricState -Resume $false }
    'ResumeFabric'    { Set-FabricState -Resume $true }
    'ReduceSchedule'  { Set-ScheduleMode -Full $false }
    'FullSchedule'    { Set-ScheduleMode -Full $true }
    'Recommendations' { Show-Recommendations }
}
