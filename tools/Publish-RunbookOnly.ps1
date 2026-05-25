<#
.SYNOPSIS
    Publish the local Invoke-AgentRunbook.ps1 to Azure Automation without rotating secrets.
.DESCRIPTION
    Uploads and publishes modules\Invoke-AgentRunbook.ps1 to the configured
    Automation Account. This is useful for code-only runbook fixes after Step 5
    has already created Key Vault secrets and Automation variables.

    It also refreshes the non-secret AgentConfig Automation variable so ADX
    endpoint/client changes from Installation_definitions.json are picked up
    without rotating app or agent secrets.
.EXAMPLE
    .\tools\Publish-RunbookOnly.ps1
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [string]$InstallationDefinitionsPath = (Join-Path $PSScriptRoot '..\config\Installation_definitions.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

$effective = Get-AAEffectiveConfig -ConfigPath $ConfigPath -InstallationDefinitionsPath $InstallationDefinitionsPath
$config = $effective.Config

$sub = $config.tenant.subscriptionId
$rg = $config.infrastructure.resourceGroup
$aaName = $config.infrastructure.automationAccountName
$location = $config.tenant.location
$runbookPath = Join-Path $PSScriptRoot '..\modules\Invoke-AgentRunbook.ps1'
if (-not (Test-Path $runbookPath)) { throw "Runbook not found: $runbookPath" }

az account set -s $sub 2>$null
$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Azure management token." }
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

# Resolve Automation Account RG without using the Azure CLI automation extension.
$aaId = az resource list --resource-type Microsoft.Automation/automationAccounts --query "[?name=='$aaName'].id | [0]" -o tsv 2>$null
if (-not $aaId) { throw "Automation Account '$aaName' was not found in subscription '$sub'." }
if ($aaId -match '/resourceGroups/([^/]+)/') { $rg = $Matches[1] }

$aaUri = "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Automation/automationAccounts/${aaName}"

Write-Host "Refreshing AgentConfig Automation variable..." -ForegroundColor Cyan
$configJson = $config | ConvertTo-Json -Depth 40
$jsonValue = $configJson | ConvertTo-Json -Compress
$varBody = @{ properties = @{ value = $jsonValue; isEncrypted = $true } } | ConvertTo-Json -Depth 4 -Compress
Invoke-RestMethod -Method PUT -Uri "$aaUri/variables/AgentConfig?api-version=2023-11-01" `
    -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($varBody)) `
    -ContentType 'application/json' -ErrorAction Stop | Out-Null
Write-Host "  [OK] AgentConfig refreshed." -ForegroundColor Green

$content = Get-Content $runbookPath -Raw -Encoding utf8
$tmpPath = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.Encoding]::UTF8)

Write-Host "Publishing runbook code only..." -ForegroundColor Cyan
Write-Host "  Automation: $aaName"
Write-Host "  Resource group: $rg"
Write-Host "  Runbook: Invoke-AgentRunbook"

$rbBody = @{ location = $location; properties = @{ runbookType = 'PowerShell72'; description = 'ClaudIA - AI content generation' } } | ConvertTo-Json -Depth 3
Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/Invoke-AgentRunbook?api-version=2023-11-01" `
    -Headers $headers -Body $rbBody -ErrorAction Stop | Out-Null

$token = az account get-access-token --query accessToken -o tsv 2>$null
Invoke-RestMethod -Method PUT -Uri "$aaUri/runbooks/Invoke-AgentRunbook/draft/content?api-version=2023-11-01" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'text/powershell' } `
    -Body ([System.IO.File]::ReadAllBytes($tmpPath)) -ErrorAction Stop | Out-Null
Remove-Item $tmpPath -Force

$token = az account get-access-token --query accessToken -o tsv 2>$null
Invoke-RestMethod -Method POST -Uri "$aaUri/runbooks/Invoke-AgentRunbook/publish?api-version=2023-11-01" `
    -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop | Out-Null

$published = Invoke-RestMethod -Uri "$aaUri/runbooks/Invoke-AgentRunbook/content?api-version=2023-11-01" `
    -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
$hasFix = $published -match 'return ,\(\[System\.Text\.Encoding\]::UTF8\.GetBytes\(\$json\)\)'

Write-Host "  Published content length: $($published.Length)"
if ($hasFix) {
    Write-Host "  [OK] Published runbook contains the JSON byte-array fix." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Published runbook does not show the JSON byte-array fix." -ForegroundColor Yellow
}
