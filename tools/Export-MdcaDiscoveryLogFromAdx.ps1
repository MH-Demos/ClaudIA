<#
.SYNOPSIS
    Export BrowserAgent ADX telemetry as an MDCA Cloud Discovery test log.
.DESCRIPTION
    Queries CLAUDIA_Activity and writes a Generic CEF-style traffic log.
    The output is intended for a controlled Cloud Discovery API/snapshot pilot.
.EXAMPLE
    .\tools\Export-MdcaDiscoveryLogFromAdx.ps1 -SinceMinutes 1440 -Top 100
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json'),
    [int]$SinceMinutes = 1440,
    [int]$Top = 100,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\out\mdca-adx-pilot.cef'),
    [string]$DefaultSourceIp = '10.50.10.25'
)

$ErrorActionPreference = 'Stop'

function Escape-CefValue {
    param([AllowNull()][object]$Value)
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $text = $text.Replace('\', '\\')
    $text = $text.Replace('=', '\=')
    $text = $text.Replace('|', '\|')
    $text = $text.Replace("`r", ' ')
    $text = $text.Replace("`n", ' ')
    return $text
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.adx -or $config.adx.enabled -ne $true) {
    throw 'ADX telemetry is not configured.'
}

if ($config.tenant.subscriptionId) {
    az account set -s $config.tenant.subscriptionId 2>$null
}

$token = az account get-access-token --resource 'https://kusto.kusto.windows.net' --query accessToken -o tsv 2>$null
if (-not $token) { throw 'Could not acquire Kusto token. Run az login first.' }

$query = @"
let defaultSourceIp = "$DefaultSourceIp";
table('$($config.adx.tableName)')
| where TimeGenerated > ago($SinceMinutes`m)
| extend e = todynamic(Event)
| extend
    username = coalesce(tostring(e.ActorUPN), tostring(e.UserPrincipalName), tostring(e.AgentUPN)),
    operation = coalesce(tostring(e.Operation), tostring(e.Action), tostring(e.ActivityType)),
    workload = coalesce(tostring(e.Workload), tostring(e.Service), tostring(e.ActivityType)),
    rawTargetDomain = tostring(e.TargetDomain),
    siteUrl = tostring(e.SiteUrl),
    appName = tostring(e.AppName),
    sourceIp = coalesce(tostring(e.SourceIp), defaultSourceIp)
| extend target_host = case(
    isnotempty(rawTargetDomain), rawTargetDomain,
    siteUrl has "sharepoint.com", extract(@"https?://([^/]+)", 1, siteUrl),
    workload has "SharePoint", "contoso.sharepoint.com",
    workload has "Outlook" or workload has "Exchange" or operation has "Email", "outlook.office.com",
    workload has "Teams", "teams.microsoft.com",
    workload has "Copilot" or operation has "AIAppInteraction", "m365.cloud.microsoft",
    workload has "Purview", "purview.microsoft.com",
    isnotempty(appName), strcat(replace_string(tolower(appName), " ", ""), ".example.com"),
    "www.office.com"
)
| extend
    target_url = strcat("https://", target_host, "/"),
    uploaded_bytes = case(
        operation has "Upload", 5242880,
        operation has "Sent" or operation has "Paste" or operation has "AIAppInteraction", 262144,
        0
    ),
    downloaded_bytes = case(
        operation has "Download" or operation has "Open", 3145728,
        65536
    )
| extend total_bytes = uploaded_bytes + downloaded_bytes
| project TimeGenerated, username, sourceIp, target_host, target_url, operation, workload, uploaded_bytes, downloaded_bytes, total_bytes
| order by TimeGenerated desc
| take $Top
"@

$body = @{ db = $config.adx.databaseName; csl = $query } | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Method POST `
    -Uri "$($config.adx.queryBaseUri.TrimEnd('/'))/v1/rest/query" `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $body -ErrorAction Stop

if (-not $result.Tables -or $result.Tables[0].Rows.Count -eq 0) {
    throw 'No ADX telemetry rows found for the requested window.'
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$lines = foreach ($row in $result.Tables[0].Rows) {
    $time = ([datetime]$row[0]).ToUniversalTime().ToString('MMM dd yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $username = Escape-CefValue $row[1]
    $sourceIp = Escape-CefValue $row[2]
    $targetHost = Escape-CefValue $row[3]
    $targetUrl = Escape-CefValue $row[4]
    $operation = Escape-CefValue $row[5]
    $workload = Escape-CefValue $row[6]
    $uploaded = [int64]$row[7]
    $downloaded = [int64]$row[8]
    $total = [int64]$row[9]

    "CEF:0|CLAUDIA|ADX Synthetic Discovery|1.0|100|Synthetic Cloud Traffic|3|rt=$time src=$sourceIp suser=$username dhost=$targetHost request=$targetUrl requestMethod=GET act=allowed in=$downloaded out=$uploaded bytes=$total destinationServiceName=$workload cs1Label=operation cs1=$operation cs2Label=synthetic cs2=true"
}

$lines | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host '=== ADX to MDCA Discovery Log Export ===' -ForegroundColor Cyan
Write-Host "  Rows:   $($lines.Count)"
Write-Host "  Output: $((Get-Item -LiteralPath $OutputPath).FullName)"

