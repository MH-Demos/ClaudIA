<#PSScriptInfo

.VERSION 1.0.0

.GUID 14141205-4bfa-4623-8070-86f59c9116ce

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
Deploy Azure infrastructure: OpenAI, Automation, Key Vault, and ADX-ready runbook hosting

.RELEASENOTES
Initial version metadata for Deploy Azure infrastructure: OpenAI, Automation, Key Vault, and ADX-ready runbook hosting.

#>
<#
.SYNOPSIS
    Deploy Azure infrastructure: OpenAI, Automation, Key Vault, and ADX-ready runbook hosting.
.DESCRIPTION
    Creates all Azure resources needed by the agent runbook. All operations are
    idempotent (safe to re-run). Uses Azure CLI + REST API.

    === RESOURCES CREATED ===

    1. RESOURCE GROUP ($Config.infrastructure.resourceGroup)
       Contains all agent resources. Default: rg-claudia-lab.

    2. AZURE OPENAI (S0 tier, $Config.infrastructure.openAiAccountName)
       Deploys GPT-4o-mini model. Used by the runbook to generate content.
       -> Customize: Change openAiModel in agents.json to use a different model.

    3. AUTOMATION ACCOUNT (Basic tier, $Config.infrastructure.automationAccountName)
       Runs the agent runbook on schedule. System-assigned Managed Identity enabled.
       MI gets: 'Cognitive Services OpenAI User' on OpenAI and Key Vault secret read access.
       -> Customize: Basic tier = $0.002/min. Free tier = 500 min/month (enough for 5 agents 1x/day).

    4. ADX telemetry is provisioned separately by tools/Deploy-AdxTelemetry.ps1.

    -> All runtime role assignments use the Automation MI principal where possible.
.PARAMETER Config
    Parsed agents.json configuration object.
#>
param($Config, [switch]$Auto)
. (Join-Path $PSScriptRoot 'Common.ps1')

$rg  = $Config.infrastructure.resourceGroup
$loc = $Config.tenant.location
$sub = $Config.tenant.subscriptionId
$kvName = Get-KeyVaultName -Config $Config

Write-Host "  Setting Azure subscription context..." -NoNewline
$setSubOutput = az account set -s $sub 2>&1
$activeSub = az account show --query id -o tsv 2>$null
if ($activeSub -ne $sub) {
    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  Azure CLI could not switch to subscription '$sub'." -ForegroundColor Red
    if ($setSubOutput) { Write-Host "  az account set: $setSubOutput" -ForegroundColor DarkYellow }
    Write-Host "  Subscriptions visible to the current Azure CLI login:" -ForegroundColor Yellow
    az account list --query "[].{Name:name, SubscriptionId:id, IsDefault:isDefault, TenantId:tenantId}" -o table
    throw "Subscription '$sub' is not available to the current Azure CLI login. Run 'az login --tenant <tenantId>' or rerun the installer fresh and select an available subscription."
}
Write-Host " [OK] $sub" -ForegroundColor Green

function Ensure-AzureProviderRegistered {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [int]$MaxAttempts = 24,
        [int]$DelaySeconds = 5
    )

    Write-Host "  Registering provider $Namespace..." -NoNewline
    $state = az provider show --namespace $Namespace --query registrationState -o tsv 2>$null
    if ($state -eq 'Registered') {
        Write-Host " [OK]" -ForegroundColor Green
        return
    }

    az provider register --namespace $Namespace -o none 2>$null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Start-Sleep -Seconds $DelaySeconds
        $state = az provider show --namespace $Namespace --query registrationState -o tsv 2>$null
        if ($state -eq 'Registered') {
            Write-Host " [OK]" -ForegroundColor Green
            return
        }
        if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
            Write-Host "." -NoNewline
        }
    }

    Write-Host " [WARN] state=$state" -ForegroundColor DarkYellow
    Write-Host "    Provider registration may still be in progress. If the next resource fails, wait a minute and rerun Step 4." -ForegroundColor Yellow
}

function Invoke-AARestWithProviderRetry {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Headers,
        [Parameter(Mandatory)]$Body,
        [string]$ProviderNamespace,
        [int]$MaxAttempts = 6
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ErrorAction Stop
        } catch {
            $message = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($ProviderNamespace -and $message -match 'MissingSubscriptionRegistration|not registered to use namespace') {
                Write-Host ""
                Write-Host "  [WAIT] $ProviderNamespace registration is not visible to ARM yet (attempt $attempt/$MaxAttempts)." -ForegroundColor DarkYellow
                Ensure-AzureProviderRegistered -Namespace $ProviderNamespace -MaxAttempts 12 -DelaySeconds 5
                Start-Sleep -Seconds 15
                $script:t = az account get-access-token --query accessToken -o tsv 2>$null
                $script:h = @{Authorization="Bearer $script:t"; 'Content-Type'='application/json'}
                $Headers = $script:h
                continue
            }
            throw
        }
    }

    throw "Provider '$ProviderNamespace' was registered but ARM did not accept it after $MaxAttempts attempts. Wait a few minutes and rerun Step 4."
}

function Get-AAOpenAIStandardQuotaKey {
    param([string]$ModelName)

    switch ($ModelName) {
        'gpt-4.1' { return 'OpenAI.Standard.gpt4.1' }
        'gpt-4.1-mini' { return 'OpenAI.Standard.gpt4.1-mini' }
        'gpt-4.1-nano' { return 'OpenAI.Standard.gpt4.1-nano' }
        'gpt-4o' { return 'OpenAI.Standard.gpt-4o' }
        'gpt-4o-mini' { return 'OpenAI.Standard.gpt-4o-mini' }
        'gpt-5.1' { return 'OpenAI.Standard.gpt-5.1' }
        'gpt-5' { return 'OpenAI.Standard.gpt-5' }
        'o4-mini' { return 'OpenAI.Standard.o4-mini' }
        'o1' { return 'OpenAI.Standard.o1' }
        default { return "OpenAI.Standard.$ModelName" }
    }
}

function Get-AAOpenAIStandardQuotaMap {
    param([string]$Location)

    $map = @{}
    $raw = az cognitiveservices usage list -l $Location -o json 2>$null
    if (-not $raw) { return $map }
    $usage = @($raw | ConvertFrom-Json)
    foreach ($item in $usage) {
        if ($item.name.value -like 'OpenAI.Standard.*') {
            $map[$item.name.value] = [PSCustomObject]@{
                Name = $item.name.value
                Label = $item.name.localizedValue
                Current = [double]$item.currentValue
                Limit = [double]$item.limit
                Available = [double]$item.limit - [double]$item.currentValue
                Unit = $item.unit
            }
        }
    }
    return $map
}

function Get-AAOpenAIChatModels {
    param([string]$AccountName, [string]$ResourceGroup, [string]$Location)

    $raw = az cognitiveservices account list-models -n $AccountName -g $ResourceGroup -o json 2>$null
    if (-not $raw) { return @() }
    $models = @($raw | ConvertFrom-Json)
    $quotaMap = Get-AAOpenAIStandardQuotaMap -Location $Location
    @($models | Where-Object {
        $_.format -eq 'OpenAI' -and
        $_.capabilities.chatCompletion -eq 'true' -and
        @($_.skus | Where-Object { $_.name -eq 'Standard' }).Count -gt 0
    } | ForEach-Object {
        $standardSku = @($_.skus | Where-Object { $_.name -eq 'Standard' } | Select-Object -First 1)
        $standardMax = if ($standardSku -and $standardSku[0].capacity.maximum) { [int]$standardSku[0].capacity.maximum } else { [int]$_.maxCapacity }
        $standardDefault = if ($standardSku -and $standardSku[0].capacity.default) { [int]$standardSku[0].capacity.default } else { 1 }
        $quotaKey = Get-AAOpenAIStandardQuotaKey -ModelName $_.name
        $quota = if ($quotaMap.ContainsKey($quotaKey)) { $quotaMap[$quotaKey] } else { $null }
        [PSCustomObject]@{
            Name = $_.name
            Version = $_.version
            LifecycleStatus = $_.lifecycleStatus
            IsDefaultVersion = [bool]$_.isDefaultVersion
            MaxCapacity = $standardMax
            DefaultCapacity = $standardDefault
            QuotaKey = $quotaKey
            QuotaLimit = if ($quota) { $quota.Limit } else { $null }
            QuotaCurrent = if ($quota) { $quota.Current } else { $null }
            QuotaAvailable = if ($quota) { $quota.Available } else { $null }
            RecommendedScore = (
                $(if ($_.lifecycleStatus -eq 'GenerallyAvailable') { 100 } elseif ($_.lifecycleStatus -eq 'Deprecating') { 50 } else { 0 }) +
                $(if ($_.isDefaultVersion) { 10 } else { 0 }) +
                $(switch ($_.name) {
                    'gpt-5.1' { 12; break }
                    'gpt-4.1-mini' { 10; break }
                    'gpt-4o-mini' { 9; break }
                    'gpt-4.1' { 8; break }
                    'gpt-4o' { 7; break }
                    default { 0 }
                })
            )
        }
    })
}

function Get-AAOpenAIImageModels {
    param([string]$AccountName, [string]$ResourceGroup)

    $raw = az cognitiveservices account list-models -n $AccountName -g $ResourceGroup -o json 2>$null
    if (-not $raw) { return @() }
    $models = @($raw | ConvertFrom-Json)
    @($models | Where-Object {
        $_.format -eq 'OpenAI' -and
        (
            $_.capabilities.imageGenerations -eq 'true' -or
            $_.capabilities.imageGeneration -eq 'true' -or
            $_.capabilities.imagesGenerations -eq 'true' -or
            $_.name -match 'dall|image'
        ) -and
        @($_.skus | Where-Object { $_.name -eq 'Standard' }).Count -gt 0
    } | ForEach-Object {
        $standardSku = @($_.skus | Where-Object { $_.name -eq 'Standard' } | Select-Object -First 1)
        $standardMax = if ($standardSku -and $standardSku[0].capacity.maximum) { [int]$standardSku[0].capacity.maximum } else { [int]$_.maxCapacity }
        $standardDefault = if ($standardSku -and $standardSku[0].capacity.default) { [int]$standardSku[0].capacity.default } else { 1 }
        [PSCustomObject]@{
            Name = $_.name
            Version = $_.version
            LifecycleStatus = $_.lifecycleStatus
            IsDefaultVersion = [bool]$_.isDefaultVersion
            MaxCapacity = $standardMax
            DefaultCapacity = $standardDefault
            RecommendedScore = (
                $(if ($_.lifecycleStatus -eq 'GenerallyAvailable') { 100 } elseif ($_.lifecycleStatus -eq 'Deprecating') { 50 } else { 0 }) +
                $(if ($_.isDefaultVersion) { 10 } else { 0 }) +
                $(switch -Regex ($_.name) {
                    'gpt-image' { 8; break }
                    'dall-e-3' { 7; break }
                    'dall-e' { 6; break }
                    default { 0 }
                })
            )
        }
    })
}

function Select-AAOpenAIChatModel {
    param(
        [array]$Models,
        [string]$ConfiguredName,
        [string]$ConfiguredVersion,
        [int]$RequestedCapacity = 0,
        [switch]$Auto
    )

    if (-not $Models -or $Models.Count -eq 0) {
        throw "No Standard chat-completion Azure OpenAI models are available for this account/region."
    }

    if ($ConfiguredName -and $ConfiguredVersion) {
        $exactCapacityMatch = $Models | Where-Object {
            $_.Name -eq $ConfiguredName -and $_.Version -eq $ConfiguredVersion -and
            ($RequestedCapacity -le 0 -or (($_.MaxCapacity -ge $RequestedCapacity) -and ($null -eq $_.QuotaAvailable -or $_.QuotaAvailable -ge $RequestedCapacity)))
        } | Select-Object -First 1
        if ($exactCapacityMatch) { return $exactCapacityMatch }
    }

    if ($ConfiguredName) {
        $sameName = @($Models | Where-Object { $_.Name -eq $ConfiguredName } | Sort-Object RecommendedScore, Version -Descending)
        $sameNameWithCapacity = @($sameName | Where-Object {
            $RequestedCapacity -le 0 -or
            (($_.MaxCapacity -ge $RequestedCapacity) -and ($null -eq $_.QuotaAvailable -or $_.QuotaAvailable -ge $RequestedCapacity))
        })
        if ($sameNameWithCapacity.Count -gt 0) {
            $chosen = $sameNameWithCapacity | Select-Object -First 1
            if (-not $ConfiguredVersion -or $ConfiguredVersion -ne $chosen.Version) {
                Write-Host "  [INFO] Model '$ConfiguredName' version '$ConfiguredVersion' is not available; using '$($chosen.Name)' version '$($chosen.Version)'." -ForegroundColor DarkYellow
            }
            return $chosen
        } elseif ($sameName.Count -gt 0 -and $RequestedCapacity -gt 0) {
            $bestSame = $sameName | Select-Object -First 1
            $quotaText = if ($null -ne $bestSame.QuotaAvailable) { " quotaAvailable=$($bestSame.QuotaAvailable)" } else { "" }
            Write-Host "  [INFO] Model '$ConfiguredName' does not satisfy requested capacity $RequestedCapacity;$quotaText. Selecting a better regional model." -ForegroundColor DarkYellow
        }
    }

    $choices = @($Models | Where-Object { $_.LifecycleStatus -ne 'Deprecated' } | Sort-Object RecommendedScore, Name, Version -Descending)
    if ($RequestedCapacity -gt 0) {
        $capacityChoices = @($choices | Where-Object {
            $_.MaxCapacity -ge $RequestedCapacity -and
            ($null -eq $_.QuotaAvailable -or $_.QuotaAvailable -ge $RequestedCapacity)
        })
        if ($capacityChoices.Count -gt 0) { $choices = $capacityChoices }
    }
    if ($choices.Count -eq 0) { $choices = @($Models | Sort-Object RecommendedScore, Name, Version -Descending) }
    $choices = @($choices | Select-Object -First 20)
    $defaultChoice = $choices | Select-Object -First 1

    if ($Auto) {
        Write-Host "  [AUTO] Selected Azure OpenAI model '$($defaultChoice.Name)' version '$($defaultChoice.Version)'." -ForegroundColor Cyan
        return $defaultChoice
    }

    Write-Host ""
    Write-Host "  Available Azure OpenAI chat models for this region:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $m = $choices[$i]
        $marker = if ($i -eq 0) { 'default' } else { '' }
        $quotaText = if ($null -ne $m.QuotaAvailable) { "quotaAvailable=$($m.QuotaAvailable)" } else { "quota=unknown" }
        Write-Host ("    [{0}] {1} | version={2} | {3} | maxCapacity={4} | {5} {6}" -f ($i + 1), $m.Name, $m.Version, $m.LifecycleStatus, $m.MaxCapacity, $quotaText, $marker) -ForegroundColor Gray
    }
    $sel = Read-Host "  Select model (1-$($choices.Count), Enter = default)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $defaultChoice }
    $idx = 0
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $choices.Count) {
        return $choices[$idx - 1]
    }
    Write-Host "  [WARN] Invalid selection. Using default '$($defaultChoice.Name)' version '$($defaultChoice.Version)'." -ForegroundColor Yellow
    return $defaultChoice
}

function Select-AAOpenAIImageModel {
    param(
        [array]$Models,
        [string]$ConfiguredName,
        [string]$ConfiguredVersion,
        [switch]$Auto
    )

    if (-not $Models -or $Models.Count -eq 0) { return $null }

    if ($ConfiguredName -and $ConfiguredVersion) {
        $exact = $Models | Where-Object { $_.Name -eq $ConfiguredName -and $_.Version -eq $ConfiguredVersion } | Select-Object -First 1
        if ($exact) { return $exact }
    }

    if ($ConfiguredName) {
        $sameName = @($Models | Where-Object { $_.Name -eq $ConfiguredName } | Sort-Object RecommendedScore, Version -Descending)
        if ($sameName.Count -gt 0) {
            $chosen = $sameName | Select-Object -First 1
            if (-not $ConfiguredVersion -or $ConfiguredVersion -ne $chosen.Version) {
                Write-Host "  [INFO] Image model '$ConfiguredName' version '$ConfiguredVersion' is not available; using '$($chosen.Name)' version '$($chosen.Version)'." -ForegroundColor DarkYellow
            }
            return $chosen
        }
    }

    $choices = @($Models | Where-Object { $_.LifecycleStatus -ne 'Deprecated' } | Sort-Object RecommendedScore, Name, Version -Descending)
    if ($choices.Count -eq 0) { $choices = @($Models | Sort-Object RecommendedScore, Name, Version -Descending) }
    $choices = @($choices | Select-Object -First 20)
    $defaultChoice = $choices | Select-Object -First 1

    if ($Auto) {
        Write-Host "  [AUTO] Selected Azure OpenAI image model '$($defaultChoice.Name)' version '$($defaultChoice.Version)'." -ForegroundColor Cyan
        return $defaultChoice
    }

    Write-Host ""
    Write-Host "  Available Azure OpenAI image models for this region:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $m = $choices[$i]
        $marker = if ($i -eq 0) { 'default' } else { '' }
        Write-Host ("    [{0}] {1} | version={2} | {3} | maxCapacity={4} {5}" -f ($i + 1), $m.Name, $m.Version, $m.LifecycleStatus, $m.MaxCapacity, $marker) -ForegroundColor Gray
    }
    Write-Host "    [S] Skip image model deployment" -ForegroundColor Gray
    $sel = Read-Host "  Select image model (1-$($choices.Count), S=skip, Enter=default)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return $defaultChoice }
    if ($sel.Trim().ToLowerInvariant() -eq 's') { return $null }
    $idx = 0
    if ([int]::TryParse($sel, [ref]$idx) -and $idx -ge 1 -and $idx -le $choices.Count) {
        return $choices[$idx - 1]
    }
    Write-Host "  [WARN] Invalid selection. Using default '$($defaultChoice.Name)' version '$($defaultChoice.Version)'." -ForegroundColor Yellow
    return $defaultChoice
}

# Resource providers are subscription-scoped. Fresh subscriptions often do not
# have these namespaces registered yet.
$requiredProviders = @(
    'Microsoft.KeyVault',
    'Microsoft.CognitiveServices',
    'Microsoft.Automation',
    'Microsoft.Insights'
)
foreach ($provider in $requiredProviders) {
    Ensure-AzureProviderRegistered -Namespace $provider
}
Write-Host ""

# Track per-resource RGs (may differ from $rg if resources pre-exist in another RG)
$aaRg  = $rg
$oaiRg = $rg

# Detect if key resources already exist in a different RG (idempotent re-deploy)
$aaName = $Config.infrastructure.automationAccountName
$aaCheck = az automation account show -n $aaName -g $rg --query name -o tsv 2>$null
if (-not $aaCheck) {
    $aaOther = az automation account list --query "[?name=='$aaName'].resourceGroup" -o tsv 2>$null
    if ($aaOther -and $aaOther -ne $rg) {
        Write-Host "  [INFO] Automation '$aaName' found in '$aaOther'" -ForegroundColor DarkYellow
        $aaRg = $aaOther
    }
}

# Resource group
Write-Host "  Creating resource group $rg..." -NoNewline
az group create -n $rg -l $loc -o none 2>$null
Write-Host " [OK]" -ForegroundColor Green

# Key Vault for agent and app credentials
Write-Host "  Creating Key Vault ($kvName)..." -NoNewline
Write-AALongRunningNotice -Activity "  Key Vault deployment"
$kvExists = az keyvault show -n $kvName -g $rg --query name -o tsv 2>$null
if ($kvExists) {
    Write-Host " [EXISTS]" -ForegroundColor DarkYellow
    $kvIdForCheck = az keyvault show -n $kvName -g $rg --query id -o tsv 2>$null
    if ($kvIdForCheck) {
        Ensure-AAResourcePublicNetworkEnabled -ResourceId $kvIdForCheck -ApiVersion '2023-07-01' -DisplayName "Key Vault $kvName" -ResourceTypeLabel 'Key Vault' | Out-Null
    }
} else {
    $kvNameAvailable = az keyvault check-name --name $kvName --query nameAvailable -o tsv 2>$null
    if ($kvNameAvailable -eq 'false') {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  Key Vault name '$kvName' is globally unavailable." -ForegroundColor Yellow
        Write-Host "  Rerun the installer from Step 0, or update keyVaultName in config\agents.json and config\Installation_definitions.json, then rerun Step 4." -ForegroundColor Yellow
        throw "Key Vault name '$kvName' is not available."
    }
    $kvCreateOutput = az keyvault create -n $kvName -g $rg -l $loc --enable-rbac-authorization true --retention-days 7 --public-network-access Enabled -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  Key Vault '$kvName' could not be created." -ForegroundColor Yellow
        Write-Host "  az output: $kvCreateOutput" -ForegroundColor DarkYellow
        throw "Key Vault creation failed for '$kvName'."
    }
    Write-Host " [OK]" -ForegroundColor Green
}
$kvId = az keyvault show -n $kvName -g $rg --query id -o tsv 2>$null
if (-not $kvId) {
    throw "Key Vault '$kvName' was not found after create/resolve."
}

# Allow the current operator to write secrets during Step 5.
$currentUserObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if ($currentUserObjectId) {
    az role assignment create --role "Key Vault Secrets Officer" --assignee-object-id $currentUserObjectId `
        --assignee-principal-type User --scope $kvId -o none 2>$null
}

# Azure OpenAI
$oaiName = $Config.infrastructure.openAiAccountName
$oaiRg = $rg
$oaiModel = $Config.infrastructure.openAiModel
$oaiModelVersion = if ($Config.infrastructure.openAiModelVersion) { [string]$Config.infrastructure.openAiModelVersion } else { '' }
$oaiTpmRaw = $Config.infrastructure.openAiTpm
$oaiTpm = 10
if ($oaiTpmRaw -and "$oaiTpmRaw" -match '^\d+$') { $oaiTpm = [int]$oaiTpmRaw }
elseif ($oaiTpmRaw) { Write-Host "  [WARN] Invalid openAiTpm '$oaiTpmRaw', using default 10" -ForegroundColor Yellow }

Write-Host "  Creating Azure OpenAI ($oaiName)..." -NoNewline
$oaiExists = az cognitiveservices account show -n $oaiName -g $rg --query name -o tsv 2>$null
if (-not $oaiExists) {
    # Check if it exists in another RG
    $oaiOther = az cognitiveservices account list --query "[?name=='$oaiName'].resourceGroup" -o tsv 2>$null
    if ($oaiOther) {
        $oaiRg = @($oaiOther -split "(`r`n|`n|`r)" | Where-Object { $_ } | Select-Object -First 1)[0]
        Write-Host " [EXISTS in $oaiOther]" -ForegroundColor DarkYellow
    } else {
        $oaiCreateOutput = az cognitiveservices account create -n $oaiName -g $rg -l $loc --kind OpenAI --sku S0 `
            --custom-domain $oaiName -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host " [FAIL]" -ForegroundColor Red
            Write-Host "  Azure OpenAI account '$oaiName' could not be created. The OpenAI custom domain is globally unique." -ForegroundColor Yellow
            Write-Host "  Rerun the installer from Step 0, or update openAiAccountName in config\agents.json and config\Installation_definitions.json, then rerun Step 4." -ForegroundColor Yellow
            Write-Host "  az output: $oaiCreateOutput" -ForegroundColor DarkYellow
            throw "Azure OpenAI account creation failed for '$oaiName'."
        }
        $createdOai = $oaiCreateOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $createdOai -or -not $createdOai.id) {
            Write-Host " [FAIL]" -ForegroundColor Red
            throw "Azure OpenAI account creation returned no resource id for '$oaiName'."
        }
        Write-Host " [OK]" -ForegroundColor Green
    }
} else {
    Write-Host " [EXISTS]" -ForegroundColor DarkYellow
}
$oaiVerified = az cognitiveservices account show -n $oaiName -g $oaiRg --query id -o tsv 2>$null
if (-not $oaiVerified) {
    throw "Azure OpenAI account '$oaiName' was not found after create/resolve. This usually means the configured name points to a resource outside the current tenant."
}

Ensure-AAResourcePublicNetworkEnabled -ResourceId $oaiVerified -ApiVersion '2024-10-01' -DisplayName "Azure OpenAI $oaiName" -ResourceTypeLabel 'Azure OpenAI' | Out-Null

# Resolve an available chat model/version for this account's region.
$availableChatModels = Get-AAOpenAIChatModels -AccountName $oaiName -ResourceGroup $oaiRg -Location $loc
$selectedChatModel = Select-AAOpenAIChatModel -Models $availableChatModels -ConfiguredName $oaiModel -ConfiguredVersion $oaiModelVersion -RequestedCapacity $oaiTpm -Auto:$Auto
$oaiModel = $selectedChatModel.Name
$oaiModelVersion = $selectedChatModel.Version
$Config.infrastructure.openAiModel = $oaiModel
if ($Config.infrastructure.PSObject.Properties['openAiModelVersion']) {
    $Config.infrastructure.openAiModelVersion = $oaiModelVersion
} else {
    $Config.infrastructure | Add-Member -NotePropertyName openAiModelVersion -NotePropertyValue $oaiModelVersion -Force
}
if ($selectedChatModel.MaxCapacity -gt 0 -and $oaiTpm -gt $selectedChatModel.MaxCapacity) {
    Write-Host "  [INFO] Requested TPM $oaiTpm exceeds model maxCapacity $($selectedChatModel.MaxCapacity); using $($selectedChatModel.MaxCapacity)." -ForegroundColor DarkYellow
    $oaiTpm = $selectedChatModel.MaxCapacity
}

# Deploy chat model (configurable via openAiModel/openAiModelVersion)
$deployAttempt = 0
$deployedChat = $false
while (-not $deployedChat -and $deployAttempt -lt 2) {
    $deployAttempt++
    Write-Host "  Deploying $oaiModel version $oaiModelVersion (capacity=$oaiTpm)..." -NoNewline
    $oaiDeploymentOutput = az cognitiveservices account deployment create -n $oaiName -g $oaiRg `
        --deployment-name $oaiModel `
        --model-name $oaiModel --model-version $oaiModelVersion `
        --model-format OpenAI --sku-capacity $oaiTpm --sku-name Standard -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
        $deployedChat = $true
        break
    }

    if ("$oaiDeploymentOutput" -match 'InsufficientQuota' -and $deployAttempt -lt 2) {
        Write-Host " [WARN]" -ForegroundColor Yellow
        Write-Host "  Insufficient quota for $oaiModel. Selecting an alternate model with available quota..." -ForegroundColor DarkYellow
        $availableChatModels = Get-AAOpenAIChatModels -AccountName $oaiName -ResourceGroup $oaiRg -Location $loc
        $alternateModels = @($availableChatModels | Where-Object { -not ($_.Name -eq $oaiModel -and $_.Version -eq $oaiModelVersion) })
        $selectedChatModel = Select-AAOpenAIChatModel -Models $alternateModels -ConfiguredName '' -ConfiguredVersion '' -RequestedCapacity $oaiTpm -Auto:$true
        $oaiModel = $selectedChatModel.Name
        $oaiModelVersion = $selectedChatModel.Version
        $Config.infrastructure.openAiModel = $oaiModel
        $Config.infrastructure.openAiModelVersion = $oaiModelVersion
        continue
    }

    Write-Host " [FAIL]" -ForegroundColor Red
    Write-Host "  az output: $oaiDeploymentOutput" -ForegroundColor DarkYellow
    throw "Azure OpenAI deployment '$oaiModel' failed."
}

# Optional: image generation (if configured)
if ($Config.infrastructure.openAiImageModel) {
    $imgModel = $Config.infrastructure.openAiImageModel
    $imgModelVersion = if ($Config.infrastructure.openAiImageModelVersion) { [string]$Config.infrastructure.openAiImageModelVersion } else { '' }
    $availableImageModels = Get-AAOpenAIImageModels -AccountName $oaiName -ResourceGroup $oaiRg
    $selectedImageModel = Select-AAOpenAIImageModel -Models $availableImageModels -ConfiguredName $imgModel -ConfiguredVersion $imgModelVersion -Auto:$Auto
    if (-not $selectedImageModel) {
        Write-Host "  [SKIP] No Standard image-generation model is available for this Azure OpenAI account/region." -ForegroundColor DarkYellow
        Write-Host "         Image scan files will use locally generated placeholders instead of Azure OpenAI images." -ForegroundColor Gray
        $Config.infrastructure.openAiImageModel = ''
        if ($Config.infrastructure.PSObject.Properties['openAiImageModelVersion']) {
            $Config.infrastructure.openAiImageModelVersion = ''
        } else {
            $Config.infrastructure | Add-Member -NotePropertyName openAiImageModelVersion -NotePropertyValue '' -Force
        }
    } else {
        $deployedImage = $false
        $failedImageModels = @()
        for ($imgAttempt = 1; $imgAttempt -le 2 -and -not $deployedImage -and $selectedImageModel; $imgAttempt++) {
            $imgModel = $selectedImageModel.Name
            $imgModelVersion = $selectedImageModel.Version
            $Config.infrastructure.openAiImageModel = $imgModel
            if ($Config.infrastructure.PSObject.Properties['openAiImageModelVersion']) {
                $Config.infrastructure.openAiImageModelVersion = $imgModelVersion
            } else {
                $Config.infrastructure | Add-Member -NotePropertyName openAiImageModelVersion -NotePropertyValue $imgModelVersion -Force
            }

            $imgCapacity = if ($selectedImageModel.DefaultCapacity -gt 0) { [int]$selectedImageModel.DefaultCapacity } else { 1 }
            if ($selectedImageModel.MaxCapacity -gt 0 -and $imgCapacity -gt $selectedImageModel.MaxCapacity) {
                $imgCapacity = $selectedImageModel.MaxCapacity
            }
            if ($imgCapacity -lt 1) { $imgCapacity = 1 }

            Write-Host "  Deploying image model $imgModel version $imgModelVersion (capacity=$imgCapacity)..." -NoNewline
            $imgDeploymentOutput = az cognitiveservices account deployment create -n $oaiName -g $oaiRg `
                --deployment-name $imgModel `
                --model-name $imgModel --model-version $imgModelVersion `
                --model-format OpenAI --sku-capacity $imgCapacity --sku-name Standard -o json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host " [OK]" -ForegroundColor Green
                $deployedImage = $true
                break
            }

            Write-Host " [WARN]" -ForegroundColor Yellow
            Write-Host "  Image model deployment failed: $imgDeploymentOutput" -ForegroundColor DarkYellow
            $failedImageModels += "$imgModel|$imgModelVersion"

            $retryableImageFailure = "$imgDeploymentOutput" -match 'InvalidResourceProperties|DeploymentModelNotSupported|Sku.*not supported|not supported in this region|InsufficientQuota|ServiceModelDeprecated|ModelDeprecated|model.*deprecated|model.*retired'
            if (-not $retryableImageFailure -or $imgAttempt -ge 2) { break }

            $availableImageModels = Get-AAOpenAIImageModels -AccountName $oaiName -ResourceGroup $oaiRg
            $alternateImageModels = @($availableImageModels | Where-Object {
                $key = "$($_.Name)|$($_.Version)"
                -not ($failedImageModels -contains $key)
            })
            if ($alternateImageModels.Count -eq 0) {
                Write-Host "  [SKIP] No alternate Standard image-generation model is available for this Azure OpenAI account/region." -ForegroundColor DarkYellow
                break
            }

            Write-Host "  Selecting an alternate image model available in this region..." -ForegroundColor DarkYellow
            $selectedImageModel = Select-AAOpenAIImageModel -Models $alternateImageModels -ConfiguredName '' -ConfiguredVersion '' -Auto:$Auto
        }

        if (-not $deployedImage) {
            Write-Host "  [SKIP] Image model deployment disabled. Scan image files will use locally generated placeholders." -ForegroundColor DarkYellow
            $Config.infrastructure.openAiImageModel = ''
            $Config.infrastructure.openAiImageModelVersion = ''
        }
    }
}

# Azure Automation (Basic tier)
$aaName = $Config.infrastructure.automationAccountName
Write-Host "  Creating Automation Account ($aaName, Basic)..." -NoNewline
$t = az account get-access-token --query accessToken -o tsv 2>$null
$h = @{Authorization="Bearer $t"; 'Content-Type'='application/json'}
$aaExists = az automation account show -n $aaName -g $aaRg --query name -o tsv 2>$null
if ($aaExists) {
    Write-Host " [EXISTS]" -ForegroundColor DarkYellow
} else {
    # Check other RGs (redundant with top-level check but defensive)
    $aaOtherRg = az automation account list --query "[?name=='$aaName'].resourceGroup" -o tsv 2>$null
    if ($aaOtherRg) {
        Write-Host " [EXISTS in $aaOtherRg]" -ForegroundColor DarkYellow
        $aaRg = $aaOtherRg
    } else {
        $aaBody = @{location=$loc; identity=@{type='SystemAssigned'}; properties=@{sku=@{name='Basic'}; publicNetworkAccess=$true}} | ConvertTo-Json -Depth 3
        Invoke-AARestWithProviderRetry -Method PUT `
            -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/${aaName}?api-version=2023-11-01" `
            -Headers $h -Body $aaBody -ProviderNamespace 'Microsoft.Automation' | Out-Null
        Write-Host " [OK]" -ForegroundColor Green
        $aaRg = $rg
    }
}

# Get MI object ID
$aaObjId = (Invoke-RestMethod "https://management.azure.com/subscriptions/$sub/resourceGroups/$aaRg/providers/Microsoft.Automation/automationAccounts/${aaName}?api-version=2023-11-01" -Headers $h).identity.principalId

$aaResourceId = "/subscriptions/$sub/resourceGroups/$aaRg/providers/Microsoft.Automation/automationAccounts/$aaName"
Ensure-AAResourcePublicNetworkEnabled -ResourceId $aaResourceId -ApiVersion '2023-11-01' -DisplayName "Automation Account $aaName" -ResourceTypeLabel 'Automation' | Out-Null

# Grant Key Vault secret read access to Automation MI and app-claudia-dataagent.
Write-Host "  Granting Key Vault secret access..." -NoNewline
az role assignment create --role "Key Vault Secrets User" --assignee-object-id $aaObjId `
    --assignee-principal-type ServicePrincipal --scope $kvId -o none 2>$null
$agentAppId = az ad app list --display-name 'app-claudia-dataagent' --query "[0].appId" -o tsv 2>$null
if ($agentAppId) {
    $agentSpObjectId = az ad sp show --id $agentAppId --query id -o tsv 2>$null
    if ($agentSpObjectId) {
        az role assignment create --role "Key Vault Secrets User" --assignee-object-id $agentSpObjectId `
            --assignee-principal-type ServicePrincipal --scope $kvId -o none 2>$null
    }
}
Write-Host " [OK]" -ForegroundColor Green

# Grant OpenAI access to MI
Write-Host "  Granting OpenAI access to Automation MI..." -NoNewline
$oaiId = az cognitiveservices account show -n $oaiName -g $oaiRg --query id -o tsv 2>$null
if (-not $oaiId) { $oaiId = az cognitiveservices account list --query "[?name=='$oaiName'].id" -o tsv 2>$null }
az role assignment create --role "Cognitive Services OpenAI User" --assignee-object-id $aaObjId `
    --assignee-principal-type ServicePrincipal --scope $oaiId -o none 2>$null
Write-Host " [OK]" -ForegroundColor Green

Write-Host "  Telemetry backend: Azure Data Explorer. Run tools\Deploy-AdxTelemetry.ps1 after Step 4 if ADX is not provisioned yet." -ForegroundColor Cyan

Write-Host "  Infrastructure deployment complete." -ForegroundColor Green

Write-AAHardeningTenantWarning



