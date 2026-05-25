<#
.SYNOPSIS
    Interactive picker to select existing Entra ID users as agent personas.
.DESCRIPTION
    Lists existing tenant users and lets you pick 5-10 users to act as agents.
    Maps each selected user to a department, wave, and workload config.
    Outputs a modified agents array to inject into agents.json.

    === HOW IT WORKS ===

    1. FETCH: Calls Graph API to list all active Member users in the tenant.
       Filters OUT accounts matching: admin*, svc-*, service*, sync_*, breakglass*.

    2. DISPLAY: Shows a numbered list with displayName, UPN, department, jobTitle.

    3. SELECT: Operator enters comma-separated numbers (e.g., 1,3,5,7,9).
       Minimum 2, maximum $MaxAgents (default 10).

    4. ASSIGN:
       - First 5 selected = Wave 1 (workload: SPO)
       - Remaining = Wave 2 (workload: Teams/Lists/Chat/Fabric/Meetings, copilotLicense=true)
       - Department: kept from Entra if valid (HR/Finance/Legal/Engineering/Sales)
         otherwise assigned round-robin
       - JobTitle: kept from Entra, or defaults to "<Dept> Specialist"
       - Topics: auto-assigned per department
       - existingUser: true (flag for the runbook to skip password generation)

    5. SAVE: Caller (Install-AutonomousAgents.ps1) writes the result to agents.json.

    -> Customize: Edit $departments array to support additional departments.
    -> Customize: Edit $defaultTopics to change what each department generates.

    === PASSWORD REQUIREMENT ===

    Since ROPC needs username + password, you must know or reset the password for
    all selected users. The wizard prompts for a shared password at Step 5.
    If users have different passwords, update AgentPwd-<sam> variables individually.
.PARAMETER Domain
    Tenant domain (e.g. contoso.onmicrosoft.com).
.PARAMETER MaxAgents
    Maximum number of agents to select (default 10).
.EXAMPLE
    $selected = .\Select-ExistingUsers.ps1 -Domain 'contoso.onmicrosoft.com'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Domain,
    [int]$MaxAgents = 10
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "=== Select Existing Users as Agents ===" -ForegroundColor Cyan
Write-Host "  Fetching users from $Domain..." -ForegroundColor Gray
Write-Host ""

# Get licensed users (exclude service accounts, guests, admin accounts)
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $token) {
    Write-Host "  [ERROR] Could not get a Microsoft Graph access token from Azure CLI." -ForegroundColor Red
    Write-Host "          Run 'az login' with an account that can read Entra users, then try again." -ForegroundColor Yellow
    return $null
}

$headers = @{Authorization="Bearer $token"; 'Content-Type'='application/json'}

$allUsers = @()
$uri = "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Member' and accountEnabled eq true&`$select=id,displayName,userPrincipalName,department,jobTitle,mail&`$top=100"
do {
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
        Write-Host "  [ERROR] Could not fetch users from Microsoft Graph." -ForegroundColor Red
        Write-Host "          Verify 'az login' is using the target tenant and the account can read Entra users." -ForegroundColor Yellow
        if ($_.ErrorDetails.Message) {
            Write-Host "          Graph response: $($_.ErrorDetails.Message)" -ForegroundColor DarkYellow
        } else {
            Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        return $null
    }
    $allUsers += $resp.value
    $uri = $resp.'@odata.nextLink'
} while ($uri)

# Filter out likely admin/service accounts
$candidates = $allUsers | Where-Object {
    $_.userPrincipalName -notmatch '^(admin|svc-|service|breakglass|sync_|on-premises)' -and
    $_.displayName -notmatch '(Admin|Service|Sync|BreakGlass|Mailbox)'
} | Sort-Object displayName, userPrincipalName

if ($candidates.Count -eq 0) {
    Write-Host "  [ERROR] No eligible users found in tenant." -ForegroundColor Red
    return $null
}

Write-Host "  Found $($candidates.Count) eligible users:" -ForegroundColor Gray
Write-Host ""

# Display numbered list
$i = 0
foreach ($u in $candidates) {
    $i++
    $dept = if ($u.department) { $u.department } else { '-' }
    $title = if ($u.jobTitle) { $u.jobTitle } else { '-' }
    Write-Host "  [$i] $($u.displayName)" -NoNewline -ForegroundColor White
    Write-Host "  ($($u.userPrincipalName))" -NoNewline -ForegroundColor Gray
    Write-Host "  [$dept / $title]" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "  Enter user numbers separated by commas (e.g. 1,3,5,7,9)" -ForegroundColor Yellow
Write-Host "  Select 5-$MaxAgents users. First 5 = Wave 1, rest = Wave 2." -ForegroundColor Yellow
$selection = Read-Host "  Selection"

$indices = $selection -split ',' | ForEach-Object { [int]$_.Trim() }
$selected = @()
foreach ($idx in $indices) {
    if ($idx -ge 1 -and $idx -le $candidates.Count) {
        $selected += $candidates[$idx - 1]
    }
}

if ($selected.Count -lt 2) {
    Write-Host "  [ERROR] Select at least 2 users." -ForegroundColor Red
    return $null
}
if ($selected.Count -gt $MaxAgents) {
    Write-Host "  [WARN] Trimming to $MaxAgents users." -ForegroundColor Yellow
    $selected = $selected | Select-Object -First $MaxAgents
}

# Department assignment -- use existing or prompt
$departments = @('HR','Finance','Legal','Engineering','Sales')
$workloads   = @('SPO','SPO','SPO','SPO','SPO','Teams','Lists','Chat','Fabric','Meetings')
$defaultTopics = @{
    HR          = @('payroll','onboarding','absences','employee files','privacy compliance')
    Finance     = @('supplier payments','quarterly reports','expense reports','budgets','tax filings')
    Legal       = @('privacy audits','employment contracts','privacy registers','litigation','NDA')
    Engineering = @('test data with PII','API specs','debug logs','code reviews','sprint reports')
    Sales       = @('sales pipeline','proposals','commissions','meeting notes','prospects')
}

Write-Host ""
Write-Host "  Configuring $($selected.Count) agents:" -ForegroundColor Cyan
Write-Host ""

$agentsOut = @()
$wave1Count = [math]::Min(5, $selected.Count)

for ($j = 0; $j -lt $selected.Count; $j++) {
    $u = $selected[$j]
    $sam = ($u.userPrincipalName -split '@')[0]
    $wave = if ($j -lt $wave1Count) { 1 } else { 2 }
    $wl = $workloads[[math]::Min($j, $workloads.Count - 1)]
    $copilot = ($wave -eq 2)

    # Department: use existing if valid, else assign round-robin
    $dept = $u.department
    if (-not $dept -or $dept -notin $departments) {
        $deptIdx = $j % $departments.Count
        $dept = $departments[$deptIdx]
        Write-Host "  [$($j+1)] $($u.displayName) -- no department set, assigning: $dept" -ForegroundColor DarkYellow
    } else {
        Write-Host "  [$($j+1)] $($u.displayName) -- department: $dept" -ForegroundColor Green
    }

    $title = if ($u.jobTitle) { $u.jobTitle } else { "$dept Specialist" }
    $topics = $defaultTopics[$dept]

    $agentsOut += [PSCustomObject]@{
        sam            = $sam
        userPrincipalName = $u.userPrincipalName
        displayName    = $u.displayName
        department     = $dept
        jobTitle       = $title
        wave           = $wave
        workload       = $wl
        copilotLicense = $copilot
        workingHours   = @{ start = 8; end = 17 }
        filesPerDay    = @(4, 7)
        emailsPerDay   = @(2, 4)
        style          = "professional, context-appropriate"
        topics         = $topics
        existingUser   = $true
    }
}

Write-Host ""
Write-Host "  Summary: $($agentsOut.Count) agents ($wave1Count Wave 1 + $($agentsOut.Count - $wave1Count) Wave 2)" -ForegroundColor Green
Write-Host ""

return $agentsOut

