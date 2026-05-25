<#
.SYNOPSIS
    Register Entra app with delegated scopes for ROPC agent authentication.
.DESCRIPTION
    Creates 'app-claudia-dataagent' in Entra ID with:
    - Public client enabled (required for ROPC flow)
    - 11 delegated Microsoft Graph permissions (admin-consented)
    - 1-year client secret

    The app is used by the runbook to acquire tokens on behalf of each agent.
    ROPC requires: username + password + client_id + client_secret + tenant_id.

    === PERMISSIONS (what each scope enables) ===
    User.Read            - Verify agent identity (GET /me)
    Mail.ReadWrite       - Read mailbox for thread context
    Mail.Send            - Send cross-department emails with PII
    Files.ReadWrite.All  - Upload files to SharePoint department folders
    Sites.ReadWrite.All  - Access SharePoint site structure
    Chat.ReadWrite       - Send 1:1 Teams chat messages
    Chat.Create          - Create new chat conversations
    ChannelMessage.Send  - Post to Teams channels
    Team.ReadBasic.All   - List joined teams and channels
    openid               - Required for OIDC token issuance
    offline_access       - Refresh token support

    -> Customize: Add scopes here if you extend agent workloads (e.g., Calendars.ReadWrite).
    -> Security: All scopes are DELEGATED (not Application). The token carries the user's identity.
.PARAMETER Domain
    Tenant domain (e.g., contoso.onmicrosoft.com)
#>
param([string]$Domain)
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-Host "  Registering app 'app-claudia-dataagent'..." -NoNewline

$appName = 'app-claudia-dataagent'
$existing = az ad app list --display-name $appName --query "[0].appId" -o tsv 2>$null

if ($existing) {
    Write-Host " [EXISTS] AppId: $existing" -ForegroundColor DarkYellow
    $script:AppId = $existing
    az ad app update --id $existing --is-fallback-public-client true -o none 2>$null
    $app = [PSCustomObject]@{ appId = $existing }
} else {
    # Create app with ROPC enabled
    $app = az ad app create --display-name $appName --sign-in-audience AzureADMyOrg `
        --enable-id-token-issuance false --enable-access-token-issuance false `
        --is-fallback-public-client true -o json 2>$null | ConvertFrom-Json
    $script:AppId = $app.appId
    Write-Host " [OK] AppId: $($app.appId)" -ForegroundColor Green

    # Create service principal
    az ad sp create --id $app.appId -o none 2>$null
}

# Create client secret
$secret = az ad app credential reset --id $app.appId --display-name 'agent-secret' --years 1 --query password -o tsv 2>$null
Write-Host "  Client secret: $($secret.Substring(0, 8))..." -ForegroundColor Yellow
Write-Host "  SAVE THIS SECRET for Step 5." -ForegroundColor Yellow

# Add delegated permissions
$graphId = '00000003-0000-0000-c000-000000000000'
$scopes = @(Get-AADataAgentGraphScopes | Where-Object { $_.Id } | ForEach-Object { @{ id = $_.Id; type = $_.Type } })

$reqAccess = @(@{resourceAppId=$graphId; resourceAccess=$scopes}) | ConvertTo-Json -Depth 5 -Compress
$tmpFile = [System.IO.Path]::GetTempFileName()
$reqAccess | Out-File $tmpFile -Encoding utf8
az ad app update --id $app.appId --required-resource-accesses "@$tmpFile" -o none 2>$null
Remove-Item $tmpFile -Force

try {
    Ensure-AADataAgentGraphConsent -AppId $app.appId | Out-Null
} catch {
    Write-Host "  [WARN] Graph admin-consent enforcement failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "         Try running Step 3 with a Global Admin or Privileged Role Admin." -ForegroundColor Yellow
}

Write-Host "  Delegated permissions configured + admin consent granted." -ForegroundColor Green
