<#PSScriptInfo

.VERSION 1.0.1
.GUID ca69ea41-4e4a-457f-883d-5989f6e2c987

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
Store agent secrets in Key Vault and deploy the runbook

.RELEASENOTES
Version 1.0.1 validates app client secrets against the configured ClaudIA tenant and fails early if a new secret cannot be generated.

#>
<#
.SYNOPSIS
    Store agent secrets in Key Vault and deploy the runbook.
.DESCRIPTION
    Uploads Invoke-AgentRunbook.ps1 to Azure Automation, stores sensitive values
    in Key Vault, stores non-secret config/secret names as Automation variables,
    and creates daily schedules.

    === AUTOMATION VARIABLES CREATED ===

    AgentTenantId      - Entra tenant ID (for ROPC token requests)
    AgentAppId         - app-claudia-dataagent application ID
    AgentKeyVaultName  - Key Vault that contains app and user credentials
    AgentClientSecretName - Key Vault secret name for app-claudia-dataagent client secret
    AgentConfig        - Full agents.json as JSON string (agent personas, infra config)
    AgentSitReference  - SIT precision patterns from config/sit-reference.txt
    AgentEmailThreads  - Multi-turn conversation scenarios from config/email-threads.json
    AgentPwdSecret-<sam> - Key Vault secret name for each agent password

    Automation variables no longer store passwords or client secret values.

    === RUNBOOK PROCESSING ===

    The runbook file is read, non-ASCII characters are replaced with '-' (Azure
    Automation PowerShell 7.2 sandboxes require ASCII), uploaded as draft, then published.

    === SCHEDULES CREATED ===

    Reads schedules[] from agents.json. Default: 3 daily schedules (09:30, 12:30, 16:00 CET).
    Each schedule is linked to the runbook with parameters: ActivityMode=full, SkipWeekendCheck=False.

    -> Customize: Edit schedules in agents.json to change frequency or timezone.
    -> Customize: Use Manage-Costs.ps1 -Action ReduceSchedule to keep morning only.
.PARAMETER Config
    Parsed agents.json configuration object.
.PARAMETER AgentPassword
    Password for all agent accounts (from Step 1).
#>
param($Config, [string]$AgentPassword)
. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-M365Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not $env:CLAUDIA_M365_AZURE_CONFIG_DIR) {
        return (& az @Arguments)
    }
    $oldConfigDir = $env:AZURE_CONFIG_DIR
    $env:AZURE_CONFIG_DIR = $env:CLAUDIA_M365_AZURE_CONFIG_DIR
    try {
        & az @Arguments
    } finally {
        if ($null -ne $oldConfigDir) { $env:AZURE_CONFIG_DIR = $oldConfigDir }
        else { Remove-Item Env:\AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    }
}

$rg = $Config.infrastructure.resourceGroup
$aaName = $Config.infrastructure.automationAccountName
$sub = $Config.tenant.subscriptionId
$domain = $Config.tenant.domain
$kvName = Get-KeyVaultName -Config $Config
az account set -s $sub 2>$null

function Get-AzureResourceAcrossSubscriptions {
    param(
        [Parameter(Mandatory)][string]$ResourceName,
        [Parameter(Mandatory)][string]$ResourceType
    )

    $accounts = @(az account list --query "[].id" -o json 2>$null | ConvertFrom-Json)
    foreach ($accountId in $accounts) {
        az account set -s $accountId 2>$null
        $resource = az resource list --resource-type $ResourceType --query "[?name=='$ResourceName'] | [0]" -o json 2>$null | ConvertFrom-Json
        if ($resource) {
            return [pscustomobject]@{
                SubscriptionId = $accountId
                ResourceGroup  = $resource.resourceGroup
                Id             = $resource.id
                Resource       = $resource
            }
        }
    }

    return $null
}

# Resolve actual RG of Automation Account (may differ from config if deployed manually)
$aaCheck = az resource show --resource-type Microsoft.Automation/automationAccounts -n $aaName -g $rg --query name -o tsv 2>$null
if (-not $aaCheck) {
    $aaResolved = Get-AzureResourceAcrossSubscriptions -ResourceName $aaName -ResourceType 'Microsoft.Automation/automationAccounts'
    if ($aaResolved) {
        if ($aaResolved.SubscriptionId -ne $sub) {
            Write-Host "  [INFO] Automation '$aaName' found in subscription '$($aaResolved.SubscriptionId)'." -ForegroundColor DarkYellow
            $sub = $aaResolved.SubscriptionId
        }
        if ($aaResolved.ResourceGroup -ne $rg) {
            Write-Host "  [INFO] Automation '$aaName' found in '$($aaResolved.ResourceGroup)' (not '$rg')" -ForegroundColor DarkYellow
            $rg = $aaResolved.ResourceGroup
        }
        az account set -s $sub 2>$null
    }
}

$t = az account get-access-token --query accessToken -o tsv 2>$null
$h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}
$aaUri = "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Automation/automationAccounts/${aaName}"

# Get app registration details. App operations may require the separate M365
# admin profile when Azure subscription admin and tenant admin are different.
# Pre-warm a Graph token so any CAE (Continuous Access Evaluation) challenge
# surfaces here rather than as an empty $appId below, which would falsely
# trigger 'Run Step 3 first.'
$graphProbe = & az account get-access-token --resource https://graph.microsoft.com --query expiresOn -o tsv 2>&1
$caePattern = 'Continuous access evaluation|InteractionRequired|TokenCreatedWithOutdatedPolicies|AADSTS50173|AADSTS70043'
if ($LASTEXITCODE -ne 0 -or ($graphProbe -is [string] -and $graphProbe -match $caePattern) -or ($graphProbe -is [array] -and ($graphProbe -join "`n") -match $caePattern)) {
    $tenantHint = if ($Config.tenant.tenantId) { " --tenant $($Config.tenant.tenantId)" } else { '' }
    throw "Azure token expired due to a Continuous Access Evaluation policy refresh. Run:`n    az logout`n    az login$tenantHint`nThen relaunch the wizard and pick Step 5 to resume."
}

$appLookupErr = $null
$appId = & {
    $err = $null
    $out = Invoke-M365Az -Arguments @('ad','app','list','--display-name','app-claudia-dataagent','--query','[0].appId','-o','tsv') 2>&1
    foreach ($line in @($out)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { $err = "$err`n$line" }
        elseif ($line -is [string] -and $line -match '^(ERROR|WARNING):') { $err = "$err`n$line" }
        elseif ($line -is [string] -and $line.Trim()) { $line }
    }
    if ($err) { $script:appLookupErr = $err }
}
$appId = ($appId | Select-Object -First 1)
$tenantId = if ($Config.tenant.tenantId) { [string]$Config.tenant.tenantId } else { az account show --query tenantId -o tsv 2>$null }
if (-not $appId) {
    if ($appLookupErr -and $appLookupErr -match $caePattern) {
        $tenantHint = if ($tenantId) { " --tenant $tenantId" } else { '' }
        throw "Azure token expired during 'az ad app list' (Continuous Access Evaluation). Run:`n    az logout`n    az login$tenantHint`nThen relaunch the wizard and pick Step 5 to resume."
    }
    throw "app-claudia-dataagent was not found. Run Step 3 first.$(if ($appLookupErr) { "`nLast error: $appLookupErr" })"
}
if (-not $tenantId) { throw "Tenant ID is missing. Re-run Step 0 or update config/agents.json tenant.tenantId." }

Write-Host "  Validating app delegated consent..." -NoNewline
try {
    Ensure-AADataAgentGraphConsent -AppId $appId | Out-Null
    Write-Host " [OK]" -ForegroundColor Green
} catch {
    Write-Host " [WARN]" -ForegroundColor Yellow
    Write-Host "  Could not verify/admin-consent app-claudia-dataagent permissions: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Run Step 3 with a Global Admin or Privileged Role Admin if ROPC returns consent_required." -ForegroundColor Yellow
}

# Get client secret (user must provide or we generate a new one)
$clientSecret = Invoke-M365Az -Arguments @('ad','app','credential','reset','--id',$appId,'--display-name','agent-deploy','--years','1','--query','password','-o','tsv') 2>$null
if ([string]::IsNullOrWhiteSpace($clientSecret)) {
    throw "Could not generate a new client secret for app-claudia-dataagent ($appId). Run Step 3 with a Global Administrator or Privileged Role Administrator, then rerun Step 5."
}

# Validate Key Vault RBAC. The runbook reads secrets with the Automation Managed
# Identity. app-claudia-dataagent is also granted Secrets User for admin validation and
# future secret-read scenarios, but ROPC itself does not read Key Vault.
$kvResourceGroup = $Config.infrastructure.resourceGroup
$kvSubscriptionId = $sub
$kvId = az keyvault show -n $kvName -g $kvResourceGroup --query id -o tsv 2>$null
if (-not $kvId) {
    $kvResolved = Get-AzureResourceAcrossSubscriptions -ResourceName $kvName -ResourceType 'Microsoft.KeyVault/vaults'
    if ($kvResolved) {
        $kvId = $kvResolved.Id
        $kvResourceGroup = $kvResolved.ResourceGroup
        $kvSubscriptionId = $kvResolved.SubscriptionId
        if ($kvSubscriptionId -ne $sub) {
            Write-Host "  [INFO] Key Vault '$kvName' found in subscription '$kvSubscriptionId'." -ForegroundColor DarkYellow
        }
    }
}
if (-not $kvId) {
    throw "Key Vault '$kvName' was not found. Re-run Step 4 or update Installation_definitions.json."
}
$aaPrincipalId = az resource show --resource-type Microsoft.Automation/automationAccounts -n $aaName -g $rg --query identity.principalId -o tsv 2>$null
$appSpObjectId = if ($appId) { az ad sp show --id $appId --query id -o tsv 2>$null } else { $null }

Write-Host "  Validating Key Vault RBAC..." -NoNewline
az account set -s $kvSubscriptionId 2>$null
if ($kvId -and $aaPrincipalId) {
    az role assignment create --role "Key Vault Secrets User" --assignee-object-id $aaPrincipalId `
        --assignee-principal-type ServicePrincipal --scope $kvId -o none 2>$null
}
if ($kvId -and $appSpObjectId) {
    az role assignment create --role "Key Vault Secrets User" --assignee-object-id $appSpObjectId `
        --assignee-principal-type ServicePrincipal --scope $kvId -o none 2>$null
}
Write-Host " [OK]" -ForegroundColor Green
az account set -s $sub 2>$null

# Remove legacy Automation variables that stored sensitive values directly. Older
# versions used AgentClientSecret and AgentPwd-<sam>; the runbook now reads those
# values from Key Vault only.
Write-Host "  Removing legacy password variables..." -NoNewline
try {
    $existingVariables = @((Invoke-RestMethod -Method GET -Uri "${aaUri}/variables?api-version=2023-11-01" -Headers $h -ErrorAction Stop).value)
    $legacyVariables = $existingVariables | Where-Object {
        $_.name -eq 'AgentClientSecret' -or
        $_.name -eq 'AgentPassword' -or
        $_.name -like 'AgentPwd-*'
    }
    foreach ($legacy in $legacyVariables) {
        Invoke-RestMethod -Method DELETE -Uri "${aaUri}/variables/$($legacy.name)?api-version=2023-11-01" -Headers $h -ErrorAction SilentlyContinue | Out-Null
    }
    if ($legacyVariables.Count -gt 0) {
        Write-Host " [OK] $($legacyVariables.Count) removed" -ForegroundColor Green
    } else {
        Write-Host " [OK] none found" -ForegroundColor Green
    }
} catch {
    Write-Host " [WARN]" -ForegroundColor Yellow
    Write-Host "  Could not enumerate/remove legacy variables: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Store sensitive credentials in Key Vault and non-secret config in Automation variables.
$secrets = @{
    'AgentTenantId' = $tenantId
    'AgentAppId' = $appId
    'AgentKeyVaultName' = $kvName
    'AgentClientSecretName' = 'agent-client-secret'
}

Write-Host "  Storing credentials in Key Vault ($kvName)..." -NoNewline
try {
    Set-AAKeyVaultSecretValue -VaultName $kvName -Name 'agent-client-secret' -Value $clientSecret
    $storedClientSecret = az keyvault secret show --vault-name $kvName --name 'agent-client-secret' --query value -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($storedClientSecret)) {
        throw "Key Vault secret 'agent-client-secret' was not stored with a client secret value."
    }

    $tokenBody = @{
        client_id     = $appId
        client_secret = $storedClientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    try {
        Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody -ErrorAction Stop | Out-Null
    } catch {
        $tokenError = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Stored Key Vault secret 'agent-client-secret' is not valid for app-claudia-dataagent ($appId): $tokenError"
    }

    foreach ($agent in $Config.agents) {
        $secretName = Get-AgentSecretName -Agent $agent -Domain $domain
        $stored = az keyvault secret show --vault-name $kvName --name $secretName --query value -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($AgentPassword)) {
            Set-AAKeyVaultSecretValue -VaultName $kvName -Name $secretName -Value $AgentPassword
            $stored = az keyvault secret show --vault-name $kvName --name $secretName --query value -o tsv 2>$null
        }
        if ([string]::IsNullOrWhiteSpace($stored)) {
            throw "Key Vault secret '$secretName' is missing. Run tools\Add-StorylineAgents.ps1 with -StoreInKeyVault for expansion users, or rerun Step 5 with -AgentPassword to write a shared password."
        }
        $secrets["AgentPwdSecret-$($agent.sam)"] = $secretName
    }
    Write-Host " [OK]" -ForegroundColor Green
} catch {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  Key Vault secret writes or validation failed." -ForegroundColor Yellow
    Write-Host "  If RBAC was just assigned, wait 1-2 minutes and rerun Step 5." -ForegroundColor Yellow
    Write-Host "  If the error is AADSTS7000215, rerun Step 3 with the Microsoft 365 admin account so ClaudIA can create a fresh app client secret." -ForegroundColor Yellow
    throw
}

# Store the effective agent config as a JSON variable (runbook reads this at startup).
# Use the merged in-memory config so ADX settings from Installation_definitions.json
# are included even when config/agents.json has not been updated yet.
$secrets['AgentConfig'] = $Config | ConvertTo-Json -Depth 40

# Store the SIT reference from locale (country-specific) or fallback to sit-reference.txt
$country = if ($Config.tenant.country) { $Config.tenant.country } else { 'FR' }
$localePath = Join-Path $PSScriptRoot "..\config\locales\$country.json"
if (Test-Path $localePath) {
    $locale = Get-Content $localePath -Raw -Encoding utf8 | ConvertFrom-Json
    $secrets['AgentSitReference'] = $locale.sitReference
    # Store the full locale JSON (runbook uses it for file types, scan templates, PII generators)
    $secrets['AgentLocale'] = Get-Content $localePath -Raw -Encoding utf8
    Write-Host "  Using $country locale (SIT reference + file types + scan templates)" -ForegroundColor Cyan
} else {
    # Fallback to the legacy sit-reference.txt file
    $sitPath = Join-Path $PSScriptRoot '..\config\sit-reference.txt'
    if (Test-Path $sitPath) {
        $secrets['AgentSitReference'] = Get-Content $sitPath -Raw -Encoding utf8
    }
    Write-Host "  [WARN] No locale for '$country' -- using legacy sit-reference.txt" -ForegroundColor Yellow
}

# Store the email threads JSON (multi-turn conversations)
$threadsPath = Join-Path $PSScriptRoot '..\config\email-threads.json'
if (Test-Path $threadsPath) {
    $secrets['AgentEmailThreads'] = Get-Content $threadsPath -Raw -Encoding utf8
}
Write-Host "  Storing $($secrets.Count) Automation variables..." -NoNewline
foreach ($kv in $secrets.GetEnumerator()) {
    # Use ConvertTo-Json to properly escape the value (handles quotes, newlines, backslashes)
    $jsonValue = $kv.Value | ConvertTo-Json -Compress
    $varBody = @{properties=@{value=$jsonValue; isEncrypted=$true}} | ConvertTo-Json -Depth 3 -Compress
    try {
        Invoke-RestMethod -Method PUT -Uri "$aaUri/variables/$($kv.Key)?api-version=2023-11-01" `
            -Headers $h -Body ([System.Text.Encoding]::UTF8.GetBytes($varBody)) `
            -ContentType 'application/json' -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ""
        Write-Host "  [WARN] Variable '$($kv.Key)' failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host " [OK]" -ForegroundColor Green

# Upload runbook
$runbookPath = Join-Path $PSScriptRoot 'Invoke-AgentRunbook.ps1'
if (-not (Test-Path $runbookPath)) {
    Write-Host "  [ERROR] Runbook not found: $runbookPath" -ForegroundColor Red
    return
}

# Drift check: the runbook carries standalone copies of Get-AgentUpn /
# Get-AgentSecretName (it cannot dot-source Common.ps1 in the AA sandbox).
# If they compute different secret names than Step 5 did, personas fail auth.
try {
    $driftErrs = $null; $driftToks = $null
    $runbookAst = [System.Management.Automation.Language.Parser]::ParseFile($runbookPath, [ref]$driftToks, [ref]$driftErrs)
    $upnFn = $runbookAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AgentUpn' }, $true)
    $secretFn = $runbookAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AgentSecretName' }, $true)
    if ($upnFn -and $secretFn) {
        $driftScope = [scriptblock]::Create(@"
param(`$ProbeAgents, `$ProbeDomain)
$($upnFn.Extent.Text)
$($secretFn.Extent.Text)
`$ProbeAgents | ForEach-Object { Get-AgentSecretName -AgentConfigItem `$_ -Domain `$ProbeDomain }
"@)
        $runbookNames = @(& $driftScope -ProbeAgents $Config.agents -ProbeDomain $domain)
        $localNames = @($Config.agents | ForEach-Object { Get-AgentSecretName -Agent $_ -Domain $domain })
        $mismatch = @(0..($localNames.Count - 1) | Where-Object { $localNames[$_] -ne $runbookNames[$_] })
        if ($mismatch.Count -gt 0) {
            Write-Host "  [WARN] Runbook helper drift: Get-AgentSecretName differs from Common.ps1 for $($mismatch.Count) agent(s) (e.g. '$($localNames[$mismatch[0]])' vs '$($runbookNames[$mismatch[0]])')." -ForegroundColor Yellow
            Write-Host "         Persona Key Vault lookups may fail at runtime. Align Get-AgentUpn/Get-AgentSecretName in modules\Invoke-AgentRunbook.ps1 with modules\Common.ps1." -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "  [WARN] Helper drift check skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "  Uploading runbook..." -NoNewline
$content = Get-Content $runbookPath -Raw -Encoding utf8
# Keep UTF-8 content intact (accents, locale-specific chars) — Azure Automation supports UTF-8
$tmpPath = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.Encoding]::UTF8)

# Refresh token (may have expired during variable storage)
$t = az account get-access-token --query accessToken -o tsv 2>$null
$h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}

# Create runbook resource first (required before uploading draft)
$rbBody = @{location=$Config.tenant.location; properties=@{runbookType='PowerShell72'; description='ClaudIA - AI content generation'}} | ConvertTo-Json -Depth 3
try {
    Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/Invoke-AgentRunbook?api-version=2023-11-01" `
        -Headers $h -Body $rbBody | Out-Null
} catch {} # Already exists

# Upload draft content + publish. A silent failure here would leave the OLD
# runbook version live in Azure Automation, so fail loudly with a retry.
try {
    $uploadAttempts = 3
    for ($attempt = 1; $attempt -le $uploadAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/Invoke-AgentRunbook/draft/content?api-version=2023-11-01" `
                -Headers @{Authorization="Bearer $t"; 'Content-Type'='text/powershell'} `
                -Body ([System.IO.File]::ReadAllBytes($tmpPath)) -ErrorAction Stop | Out-Null
            Invoke-RestMethod -Method POST -Uri "$aaUri/runbooks/Invoke-AgentRunbook/publish?api-version=2023-11-01" `
                -Headers $h -ErrorAction Stop | Out-Null
            break
        } catch {
            if ($attempt -lt $uploadAttempts) {
                Write-Host " [retry $attempt/$uploadAttempts]" -ForegroundColor DarkYellow -NoNewline
                Start-Sleep -Seconds (15 * $attempt)
            } else {
                Write-Host " [FAIL]" -ForegroundColor Red
                Write-Host "  Runbook upload/publish failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "  The previously published runbook version (if any) is still live. Rerun Step 5 or tools\Publish-RunbookOnly.ps1." -ForegroundColor Yellow
                throw
            }
        }
    }
} finally {
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
}
Write-Host " [OK]" -ForegroundColor Green

# Create schedules. List existing runbook-schedule links first: jobSchedules are
# keyed by GUID, so re-linking on every rerun would stack duplicate daily runs.
$existingLinks = @()
try {
    $existingLinks = @((Invoke-RestMethod -Method GET -Uri "$aaUri/jobSchedules?api-version=2023-11-01" -Headers $h -ErrorAction Stop).value)
} catch {
    Write-Host "  [WARN] Could not list existing job schedules: $($_.Exception.Message)" -ForegroundColor Yellow
}
foreach ($sched in $Config.schedules) {
    Write-Host "  Creating schedule $($sched.name)..." -NoNewline
    $startTime = (Get-Date).AddDays(1).ToString('yyyy-MM-dd') + "T$($sched.hour.ToString('D2')):$($sched.minute.ToString('D2')):00Z"
    $schedBody = @{properties=@{frequency='Day'; interval=1; startTime=$startTime; timeZone=$sched.timezone; description="Daily agent activity ($($sched.name))"}} | ConvertTo-Json -Depth 3
    try {
        Invoke-RestMethod -Method PUT -Uri "$aaUri/schedules/$($sched.name)?api-version=2023-11-01" `
            -Headers $h -Body $schedBody -ErrorAction Stop | Out-Null
    } catch {
        # PUT on an existing schedule that is already linked returns a conflict; keep going.
        if ($_.Exception.Message -notmatch '409|[Cc]onflict') {
            Write-Host " [WARN] schedule: $($_.Exception.Message)" -ForegroundColor Yellow -NoNewline
        }
    }

    $alreadyLinked = $existingLinks | Where-Object {
        $_.properties.runbook.name -eq 'Invoke-AgentRunbook' -and $_.properties.schedule.name -eq $sched.name
    } | Select-Object -First 1
    if ($alreadyLinked) {
        Write-Host " [OK] already linked" -ForegroundColor Green
        continue
    }

    # Link schedule to runbook
    $linkBody = @{properties=@{runbook=@{name='Invoke-AgentRunbook'}; schedule=@{name=$sched.name}; parameters=@{ActivityMode='full'; SkipWeekendCheck='False'}}} | ConvertTo-Json -Depth 4
    try {
        Invoke-RestMethod -Method PUT -Uri "$aaUri/jobSchedules/$(New-Guid)?api-version=2023-11-01" `
            -Headers $h -Body $linkBody -ErrorAction Stop | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FAIL] link: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "  Runbook deployed with $($Config.schedules.Count) daily schedules." -ForegroundColor Green




