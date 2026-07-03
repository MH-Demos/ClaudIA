# =============================================================================
# AZURE OPENAI - content generation via Managed Identity
# =============================================================================
function Get-OaiToken {
    # Azure Automation sandboxes don't support IMDS; use Az module token
    $azToken = (Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com/').Token
    $azToken
}

function Invoke-OAI {
    param([string]$OaiToken, [string]$SystemPrompt, [string]$UserPrompt, [int]$MaxTokens = 1500, [string]$UserId = '')

    $body = @{
        messages = @(
            @{ role = 'system'; content = (ConvertTo-AASafeText -Text $SystemPrompt -MaxLength 12000) }
            @{ role = 'user';   content = (ConvertTo-AASafeText -Text $UserPrompt -MaxLength 20000) }
        )
        max_completion_tokens = $MaxTokens
        temperature = 0.9
    }
    # Inject agent UPN as 'user' field for Azure OpenAI request attribution.
    # First-party activity telemetry is written directly to ADX.
    if ($UserId) { $body.user = $UserId }

    $jsonBody = ConvertTo-AAJsonBody -Value $body -Depth 8

    $uri = "${OaiEndpoint}openai/deployments/${OaiDeployment}/chat/completions?api-version=2024-02-01"

    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $OaiToken"; 'Content-Type' = 'application/json' } `
            -ContentType 'application/json' -Body $jsonBody
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure OpenAI chat completion failed. $details"
    }

    $resp.choices[0].message.content
}

function Get-FoundryToken {
    try {
        $token = (Get-AzAccessToken -ResourceUrl 'https://ai.azure.com/' -ErrorAction Stop).Token
        if ($token) { return $token }
    } catch {}
    try {
        return (Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com/' -ErrorAction Stop).Token
    } catch {
        throw "Could not acquire a bearer token for Azure AI Foundry. $($_.Exception.Message)"
    }
}

function Invoke-FoundryChatCompletion {
    param(
        [string]$Endpoint,
        [string]$DeploymentName,
        [string]$SystemPrompt,
        [string]$UserPrompt,
        [int]$MaxTokens = 900,
        [string]$UserId = ''
    )

    $cleanEndpoint = (ConvertTo-AAPlainString $Endpoint).TrimEnd('/')
    $deployment = ConvertTo-AAPlainString $DeploymentName
    if ([string]::IsNullOrWhiteSpace($cleanEndpoint) -or [string]::IsNullOrWhiteSpace($deployment)) {
        throw "Foundry endpoint or deployment name is empty."
    }

    $uri = if ($cleanEndpoint -match '/chat/completions$') {
        $cleanEndpoint
    } elseif ($cleanEndpoint -match '/openai/v1$') {
        "$cleanEndpoint/chat/completions"
    } elseif ($cleanEndpoint -match '\.openai\.azure\.com$') {
        "$cleanEndpoint/openai/v1/chat/completions"
    } else {
        "$cleanEndpoint/models/chat/completions?api-version=2024-05-01-preview"
    }

    $body = @{
        model = $deployment
        messages = @(
            @{ role = 'system'; content = (ConvertTo-AASafeText -Text $SystemPrompt -MaxLength 12000) }
            @{ role = 'user';   content = (ConvertTo-AASafeText -Text $UserPrompt -MaxLength 20000) }
        )
        max_completion_tokens = $MaxTokens
        temperature = 0.3
    }
    if ($UserId) { $body.user = $UserId }

    $token = Get-FoundryToken
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -ContentType 'application/json' -Body (ConvertTo-AAJsonBody -Value $body -Depth 8)
        return $resp.choices[0].message.content
    } catch {
        $details = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Azure AI Foundry chat completion failed. $details"
    }
}

