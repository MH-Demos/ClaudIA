function Get-AgentUpn {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][string]$Domain
    )

    if ($Agent.userPrincipalName) { return [string]$Agent.userPrincipalName }
    if ($Agent.upn) { return [string]$Agent.upn }
    if ("$($Agent.sam)" -match '@') { return [string]$Agent.sam }
    return "$($Agent.sam)@$Domain"
}

function Get-AgentSecretName {
    param(
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)][string]$Domain
    )

    $upn = Get-AgentUpn -Agent $Agent -Domain $Domain
    $local = ($upn -split '@')[0].ToLowerInvariant()
    $name = $local -replace '[^a-z0-9-]', '-'
    $name = $name -replace '-+', '-'
    return $name.Trim('-')
}

function Get-KeyVaultName {
    param($Config)

    if ($Config.infrastructure.keyVaultName) { return [string]$Config.infrastructure.keyVaultName }

    $seed = "$($Config.tenant.subscriptionId)-$($Config.infrastructure.resourceGroup)-aa"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $suffix = ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
    $base = ($Config.infrastructure.resourceGroup -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($base.Length -gt 11) { $base = $base.Substring(0, 11) }
    return "kv$base$suffix"
}

function Set-AAObjectProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Merge-AAInstallationDefinitionsIntoConfig {
    param(
        [Parameter(Mandatory)]$Config,
        $Definitions
    )

    if (-not $Definitions) { return $Config }

    if ($Definitions.tenant) {
        foreach ($prop in @('domain','tenantId','subscriptionId','location','country')) {
            if ($Definitions.tenant.PSObject.Properties[$prop] -and $null -ne $Definitions.tenant.$prop -and "$($Definitions.tenant.$prop)" -ne '') {
                Set-AAObjectProperty -Object $Config.tenant -Name $prop -Value $Definitions.tenant.$prop
            }
        }
    }

    if ($Definitions.infrastructure) {
        foreach ($prop in @(
            'resourceGroup','automationAccountName','openAiAccountName','openAiModel',
            'openAiModelVersion','openAiImageModel','openAiImageModelVersion','openAiTpm',
            'workbookEnabled','fabricEnabled','keyVaultName'
        )) {
            if ($Definitions.infrastructure.PSObject.Properties[$prop]) {
                Set-AAObjectProperty -Object $Config.infrastructure -Name $prop -Value $Definitions.infrastructure.$prop
            }
        }
    }

    if ($Definitions.adx) {
        if ($Config.PSObject.Properties['adx']) {
            $Config.adx = $Definitions.adx
        } else {
            $Config | Add-Member -NotePropertyName adx -NotePropertyValue $Definitions.adx -Force
        }
    } elseif ($Definitions.steps -and $Definitions.steps.PSObject.Properties['4'] -and $Definitions.steps.'4'.adx) {
        if ($Config.PSObject.Properties['adx']) {
            $Config.adx = $Definitions.steps.'4'.adx
        } else {
            $Config | Add-Member -NotePropertyName adx -NotePropertyValue $Definitions.steps.'4'.adx -Force
        }
    }

    if ($Definitions.agents -and @($Definitions.agents).Count -gt 0) {
        $Config.agents = @($Definitions.agents)
    } elseif ($Definitions.selectedUsers -and @($Definitions.selectedUsers).Count -gt 0) {
        $Config.agents = @($Definitions.selectedUsers)
    }

    return $Config
}

function Get-AAEffectiveConfig {
    param(
        [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\agents.json'),
        [string]$InstallationDefinitionsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\Installation_definitions.json'),
        [switch]$RequireInstallationDefinitions
    )

    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $config = Get-Content $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json

    $definitions = $null
    if (Test-Path $InstallationDefinitionsPath) {
        $definitions = Get-Content $InstallationDefinitionsPath -Raw -Encoding utf8 | ConvertFrom-Json
        $config = Merge-AAInstallationDefinitionsIntoConfig -Config $config -Definitions $definitions
    } elseif ($RequireInstallationDefinitions) {
        throw "Installation definitions not found: $InstallationDefinitionsPath"
    }

    return [PSCustomObject]@{
        Config = $config
        Definitions = $definitions
        ConfigPath = $ConfigPath
        InstallationDefinitionsPath = $InstallationDefinitionsPath
    }
}

function Get-AADataAgentGraphScopes {
    return @(
        [PSCustomObject]@{ Id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'; Type = 'Scope'; Value = 'User.Read' }
        [PSCustomObject]@{ Id = 'b4e74841-8e56-480b-be8b-910348b18b4c'; Type = 'Scope'; Value = 'Mail.ReadWrite' }
        [PSCustomObject]@{ Id = 'e383f46e-2787-4529-855e-0e479a3ffac0'; Type = 'Scope'; Value = 'Mail.Send' }
        [PSCustomObject]@{ Id = '863451e7-0667-486c-a5d6-d135439485f0'; Type = 'Scope'; Value = 'Files.ReadWrite.All' }
        [PSCustomObject]@{ Id = '640ddd16-e5b7-4d71-9690-3f4022f5acd2'; Type = 'Scope'; Value = 'Sites.ReadWrite.All' }
        [PSCustomObject]@{ Id = '9ff7295e-131b-4d94-90e1-69fde507ac11'; Type = 'Scope'; Value = 'Chat.ReadWrite' }
        [PSCustomObject]@{ Id = '38826093-1571-4db0-8f04-29f0a5a46a30'; Type = 'Scope'; Value = 'ChannelMessage.Send' }
        [PSCustomObject]@{ Id = '485be79e-c497-4b35-9400-0e3fa7f2a5d4'; Type = 'Scope'; Value = 'Chat.Create' }
        [PSCustomObject]@{ Id = '660b7406-55f1-41ca-a0ed-0b035e182f3e'; Type = 'Scope'; Value = 'Team.ReadBasic.All' }
        [PSCustomObject]@{ Id = '37f7f235-527c-4136-accd-4a02d197296e'; Type = 'Scope'; Value = 'openid' }
        [PSCustomObject]@{ Id = '7427e0e9-2fba-42fe-b0c0-848c9e6a8182'; Type = 'Scope'; Value = 'offline_access' }
        [PSCustomObject]@{ Id = ''; Type = 'Scope'; Value = 'InformationProtectionPolicy.Read' }
    )
}

function Ensure-AADataAgentGraphConsent {
    param([Parameter(Mandatory)][string]$AppId)

    $graphId = '00000003-0000-0000-c000-000000000000'
    $scopes = @(Get-AADataAgentGraphScopes)
    $scopeText = ($scopes | ForEach-Object { $_.Value }) -join ' '

    az ad app update --id $AppId --is-fallback-public-client true -o none 2>$null

    $graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $graphToken) { throw "Could not acquire Microsoft Graph token. Run az login with a Global Admin or Privileged Role Admin account." }
    $graphHeaders = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' }

    $appObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $appObject) { throw "Application '$AppId' was not found in Microsoft Graph." }

    $spObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $spObject) {
        az ad sp create --id $AppId -o none 2>$null
        Start-Sleep -Seconds 5
        $spObject = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'" -Headers $graphHeaders).value | Select-Object -First 1
    }
    if (-not $spObject) { throw "Service principal for app '$AppId' was not found or could not be created." }

    $graphSp = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphId'" -Headers $graphHeaders).value | Select-Object -First 1
    if (-not $graphSp) { throw "Microsoft Graph service principal was not found in this tenant." }

    $resolvedScopes = @()
    foreach ($scope in $scopes) {
        $scopeId = $scope.Id
        if ([string]::IsNullOrWhiteSpace($scopeId)) {
            $scopeId = ($graphSp.oauth2PermissionScopes | Where-Object { $_.value -eq $scope.Value } | Select-Object -First 1).id
        }
        if (-not $scopeId) {
            throw "Microsoft Graph delegated permission '$($scope.Value)' was not found in this tenant."
        }
        $resolvedScopes += [PSCustomObject]@{ Id = $scopeId; Type = $scope.Type; Value = $scope.Value }
    }

    $manifestBody = @{
        requiredResourceAccess = @(
            @{
                resourceAppId = $graphId
                resourceAccess = @($resolvedScopes | ForEach-Object { @{ id = $_.Id; type = $_.Type } })
            }
        )
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($appObject.id)" `
        -Headers $graphHeaders -Body $manifestBody | Out-Null

    $grants = @((Invoke-RestMethod "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($spObject.id)' and resourceId eq '$($graphSp.id)'" -Headers $graphHeaders).value)
    $tenantGrant = $grants | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if ($tenantGrant) {
        Invoke-RestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($tenantGrant.id)" `
            -Headers $graphHeaders -Body (@{ scope = $scopeText } | ConvertTo-Json) | Out-Null
    } else {
        $grantBody = @{
            clientId    = $spObject.id
            consentType = 'AllPrincipals'
            resourceId  = $graphSp.id
            scope       = $scopeText
        } | ConvertTo-Json -Depth 4
        Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            -Headers $graphHeaders -Body $grantBody | Out-Null
    }

    az ad app permission admin-consent --id $AppId 2>$null
    $updatedGrants = @((Invoke-RestMethod "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($spObject.id)' and resourceId eq '$($graphSp.id)'" -Headers $graphHeaders).value)
    $updatedTenantGrant = $updatedGrants | Where-Object { $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    if (-not $updatedTenantGrant) {
        throw "Tenant-wide delegated consent (AllPrincipals) was not found after repair."
    }

    return [PSCustomObject]@{
        AppId = $AppId
        ServicePrincipalId = $spObject.id
        Scope = $scopeText
        TenantGrantId = $updatedTenantGrant.id
        ExistingPrincipalGrantCount = @($updatedGrants | Where-Object { $_.consentType -eq 'Principal' }).Count
    }
}

function Set-AADeploymentResult {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$MainActivity,
        [Parameter(Mandatory)][ValidateSet('deployed','skipped','failed')][string]$Status,
        [string]$Comments = ''
    )

    if (-not $script:AADeploymentResults) { $script:AADeploymentResults = @() }
    $script:AADeploymentResults += [PSCustomObject]@{
        Step = $Step
        'Main Activity' = $MainActivity
        Status = $Status
        Comments = $Comments
    }
}

function Write-AALongRunningNotice {
    param([string]$Activity)

    Write-Host "  $Activity can take several minutes. Please be patient while Azure finishes provisioning." -ForegroundColor DarkYellow
}

function Close-AAConnections {
    param([switch]$IncludeAzureCliLogout)

    $closed = [ordered]@{
        PowerShellSessions = 0
        ExchangeOnline = 'not-loaded'
        MicrosoftGraph = 'not-loaded'
        AzContext = 'not-loaded'
        PnPOnline = 'not-loaded'
        AzureCli = if ($IncludeAzureCliLogout) { 'requested' } else { 'preserved' }
        Errors = @()
    }

    try {
        $sessions = @(Get-PSSession -ErrorAction SilentlyContinue)
        if ($sessions.Count -gt 0) {
            $sessions | Remove-PSSession -ErrorAction SilentlyContinue
            $closed.PowerShellSessions = $sessions.Count
        }
    } catch { $closed.Errors += "PSSession: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $closed.ExchangeOnline = 'closed'
        }
    } catch { $closed.Errors += "ExchangeOnline: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $closed.MicrosoftGraph = 'closed'
        }
    } catch { $closed.Errors += "MicrosoftGraph: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-AzAccount -ErrorAction SilentlyContinue) {
            Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
            Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
            $closed.AzContext = 'closed-process-scope'
        }
    } catch { $closed.Errors += "AzContext: $($_.Exception.Message)" }

    try {
        if (Get-Command Disconnect-PnPOnline -ErrorAction SilentlyContinue) {
            Disconnect-PnPOnline -ErrorAction SilentlyContinue | Out-Null
            $closed.PnPOnline = 'closed'
        }
    } catch { $closed.Errors += "PnPOnline: $($_.Exception.Message)" }

    if ($IncludeAzureCliLogout) {
        try {
            az logout 2>$null
            $closed.AzureCli = 'logged-out'
        } catch { $closed.Errors += "AzureCli: $($_.Exception.Message)" }
    }

    return [PSCustomObject]$closed
}

function Initialize-AAInstallationDefinitions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunLogPath,
        [Parameter(Mandatory)][string]$RunStamp,
        [switch]$Fresh
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    if ((Test-Path $Path) -and -not $Fresh) {
        $script:AAInstallationDefinitions = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
    } else {
        $script:AAInstallationDefinitions = [PSCustomObject][ordered]@{
            schemaVersion = '1.0'
            runId = $RunStamp
            createdAt = (Get-Date).ToString('o')
            updatedAt = (Get-Date).ToString('o')
            sourceConfigPath = $ConfigPath
            runLogPath = $RunLogPath
            tenant = [ordered]@{}
            infrastructure = [ordered]@{}
            agents = @()
            selectedUsers = @()
            environmentScan = [ordered]@{}
            steps = [ordered]@{}
            sessionReset = $null
            notes = @()
        }
    }

    $script:AAInstallationDefinitions.sourceConfigPath = $ConfigPath
    $script:AAInstallationDefinitions.runLogPath = $RunLogPath
    $script:AAInstallationDefinitions.tenant = [ordered]@{
        domain = $Config.tenant.domain
        tenantId = $Config.tenant.tenantId
        subscriptionId = $Config.tenant.subscriptionId
        location = $Config.tenant.location
        country = $Config.tenant.country
    }
    $script:AAInstallationDefinitions.infrastructure = [ordered]@{
        resourceGroup = $Config.infrastructure.resourceGroup
        automationAccountName = $Config.infrastructure.automationAccountName
        openAiAccountName = $Config.infrastructure.openAiAccountName
        openAiModel = $Config.infrastructure.openAiModel
        openAiModelVersion = $Config.infrastructure.openAiModelVersion
        openAiImageModel = $Config.infrastructure.openAiImageModel
        openAiImageModelVersion = $Config.infrastructure.openAiImageModelVersion
        openAiTpm = $Config.infrastructure.openAiTpm
        fabricEnabled = $Config.infrastructure.fabricEnabled
        keyVaultName = Get-KeyVaultName -Config $Config
    }
    $script:AAInstallationDefinitions.agents = @($Config.agents | ForEach-Object {
        [ordered]@{
            sam = $_.sam
            userPrincipalName = if ($_.userPrincipalName) { $_.userPrincipalName } else { $null }
            displayName = $_.displayName
            department = $_.department
            jobTitle = $_.jobTitle
            wave = $_.wave
            workload = $_.workload
            copilotLicense = $_.copilotLicense
            existingUser = $_.existingUser
            workingHours = $_.workingHours
            filesPerDay = $_.filesPerDay
            emailsPerDay = $_.emailsPerDay
            style = $_.style
            topics = $_.topics
            keyVaultSecretName = Get-AgentSecretName -Agent $_ -Domain $Config.tenant.domain
        }
    })
    if ($Config.adx) {
        if ($script:AAInstallationDefinitions.PSObject.Properties['adx']) {
            $script:AAInstallationDefinitions.adx = $Config.adx
        } else {
            $script:AAInstallationDefinitions | Add-Member -NotePropertyName adx -NotePropertyValue $Config.adx -Force
        }
    }

    Save-AAInstallationDefinitions -Path $Path
}

function Save-AAInstallationDefinitions {
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:AAInstallationDefinitions) { return }
    $script:AAInstallationDefinitions.updatedAt = (Get-Date).ToString('o')
    $script:AAInstallationDefinitions | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding utf8
}

function Set-AAInstallationDefinition {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)]$Value
    )

    if (-not $script:AAInstallationDefinitions) { return }
    if ($script:AAInstallationDefinitions.PSObject.Properties[$Section]) {
        $script:AAInstallationDefinitions.$Section = $Value
    } else {
        $script:AAInstallationDefinitions | Add-Member -NotePropertyName $Section -NotePropertyValue $Value -Force
    }
    Save-AAInstallationDefinitions -Path $Path
}

function Set-AAInstallationStepDefinition {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)]$Value
    )

    if (-not $script:AAInstallationDefinitions) { return }
    # Add-Member -NotePropertyName rejects some numeric strings because they can
    # be converted to PSMemberTypes enum values. PSNoteProperty avoids that trap.
    if (-not $script:AAInstallationDefinitions.steps) {
        $script:AAInstallationDefinitions.steps = [PSCustomObject][ordered]@{}
    }
    $existing = $script:AAInstallationDefinitions.steps.PSObject.Properties[$Step]
    if ($existing) {
        $existing.Value = $Value
    } else {
        $script:AAInstallationDefinitions.steps.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new($Step, $Value)
        )
    }
    Save-AAInstallationDefinitions -Path $Path
}
