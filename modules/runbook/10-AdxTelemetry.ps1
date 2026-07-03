# =============================================================================
# AZURE DATA EXPLORER - push agent activity directly (workaround: OAI diagnostics
# don't include the 'user' field from the request body)
# =============================================================================
$script:adxIngestBaseUri = $null
$script:adxDatabase      = $null
$script:adxTable         = $null
$script:adxMapping       = $null
$script:adxToken         = $null
$script:adxTokenAcquiredAt = $null
$script:adxTenantIdForRefresh = $null
$script:adxClientIdForRefresh = $null
$script:adxClientSecretForRefresh = $null
$script:graphThrottle429Count = 0
$script:graphLastThrottleAt = $null

function Get-AdxAppToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://kusto.kusto.windows.net/.default'
        grant_type    = 'client_credentials'
    }
    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body -TimeoutSec 60 -ErrorAction Stop
    return $tokenResponse.access_token
}

function Initialize-AdxIngestion {
    if (-not $adxConfig -or $adxConfig.enabled -ne $true) {
        Write-Warning "  [ADX] ADX telemetry is not configured. Agent telemetry will not be ingested."
        return
    }

    try {
        $adxKeyVaultName = if ($adxConfig.keyVaultName) { [string]$adxConfig.keyVaultName } else { $keyVaultName }
        $adxSecretName = if ($adxConfig.clientSecretName) { [string]$adxConfig.clientSecretName } else { [string]$clientSecretName }
        if ([string]::IsNullOrWhiteSpace($adxSecretName)) { $adxSecretName = 'agent-client-secret' }
        $adxSecret = Get-KeyVaultSecretValue -VaultName $adxKeyVaultName -SecretName $adxSecretName
        if ([string]::IsNullOrWhiteSpace($adxSecret)) {
            throw "ADX client secret '$adxSecretName' is empty or missing in Key Vault '$adxKeyVaultName'."
        }

        # Streaming ingest REST uses the cluster URI, not the queued ingest URI.
        $script:adxIngestBaseUri = ConvertTo-AAPlainString $adxConfig.queryBaseUri
        if ([string]::IsNullOrWhiteSpace($script:adxIngestBaseUri)) {
            $script:adxIngestBaseUri = ConvertTo-AAPlainString $adxConfig.ingestBaseUri
        }
        $script:adxDatabase = ConvertTo-AAPlainString $adxConfig.databaseName
        $script:adxTable = ConvertTo-AAPlainString $adxConfig.tableName
        $script:adxMapping = ConvertTo-AAPlainString $adxConfig.mappingName
        $script:adxToken = Get-AdxAppToken -TenantId $adxConfig.tenantId -ClientId $adxConfig.clientId -ClientSecret $adxSecret
        # Keep what is needed to refresh the app token mid-run: client-credential
        # tokens live ~1h and a full run (10 agents + threads) can exceed that.
        $script:adxTokenAcquiredAt = Get-Date
        $script:adxTenantIdForRefresh = $adxConfig.tenantId
        $script:adxClientIdForRefresh = $adxConfig.clientId
        $script:adxClientSecretForRefresh = $adxSecret
        Write-Output "  [ADX] Ingestion initialized for $($script:adxDatabase).$($script:adxTable)"
    }
    catch {
        Write-Warning "  [ADX] Failed to initialize ingestion: $($_.Exception.Message)"
    }
}

function Push-AgentActivity {
    param(
        [string]$AgentUPN,
        [string]$AgentName,
        [string]$Department,
        [string]$ActivityType,   # file, email, teams, chat, fabric, copilot, thread, external_ai
        [string]$Detail,
        [int]$TokensIn = 0,
        [int]$TokensOut = 0,
        [string]$PromptContent = '',
        [string]$ResponseContent = '',
        [hashtable]$Properties = @{}
    )
    if (-not $script:adxToken -or -not $script:adxIngestBaseUri) { return }

    # Refresh the ADX app token before it expires (~60 min lifetime): long runs
    # previously failed every ingest silently once the initial token aged out.
    if ($script:adxTokenAcquiredAt -and ((Get-Date) - $script:adxTokenAcquiredAt).TotalMinutes -gt 50 -and $script:adxClientSecretForRefresh) {
        try {
            $script:adxToken = Get-AdxAppToken -TenantId $script:adxTenantIdForRefresh -ClientId $script:adxClientIdForRefresh -ClientSecret $script:adxClientSecretForRefresh
            $script:adxTokenAcquiredAt = Get-Date
            Write-Output "  [ADX] App token refreshed"
        }
        catch {
            Write-Warning "  [ADX] Token refresh failed (keeping current token): $($_.Exception.Message)"
        }
    }

    # Keep payloads compact and bounded for near-real-time ingestion.
    if ($PromptContent.Length -gt 30000) { $PromptContent = $PromptContent.Substring(0, 30000) + '...[truncated]' }
    if ($ResponseContent.Length -gt 30000) { $ResponseContent = $ResponseContent.Substring(0, 30000) + '...[truncated]' }

    $event = @{
        AgentUPN        = $AgentUPN
        AgentName       = $AgentName
        Department      = $Department
        ActivityType    = $ActivityType
        Detail          = $Detail
        PromptTokens    = $TokensIn
        ResponseTokens  = $TokensOut
        PromptContent   = $PromptContent
        ResponseContent = $ResponseContent
        ActorUPN        = $AgentUPN
        ActorName       = $AgentName
        ActorDepartment = $Department
    }
    foreach ($key in $Properties.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
            $event[$key] = $Properties[$key]
        }
    }

    $record = @{
        TimeGenerated = (Get-Date).ToUniversalTime().ToString('o')
        Event = $event
    } | ConvertTo-Json -Depth 10 -Compress

    $encodedDb = [System.Uri]::EscapeDataString($script:adxDatabase)
    $encodedTable = [System.Uri]::EscapeDataString($script:adxTable)
    $encodedMapping = [System.Uri]::EscapeDataString($script:adxMapping)
    $ingestUri = "$($script:adxIngestBaseUri.TrimEnd('/'))/v1/rest/ingest/$encodedDb/${encodedTable}?streamFormat=json&mappingName=$encodedMapping"

    try {
        Invoke-RestMethod -Method POST `
            -Uri $ingestUri `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $($script:adxToken)" } `
            -Body $record -TimeoutSec 120 | Out-Null
    }
    catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "  [ADX] Failed to ingest activity '$ActivityType' for '$AgentName': $details"
    }
}

