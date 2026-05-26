<#PSScriptInfo

.VERSION 1.0.0
.GUID 0c0413d4-3a37-4df1-a91a-26e28397220f

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Automation Microsoft365 Azure Purview BrowserAgents

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
List, add, or remove lab-controlled external recipients used by BrowserAgents

.RELEASENOTES
Initial version metadata for List, add, or remove lab-controlled external recipients used by BrowserAgents.

#>
[CmdletBinding()]
param(
    [ValidateSet('List','Add','Remove','Clear')]
    [string]$Action = 'List',
    [string[]]$Recipient,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\agents.json')
)

$ErrorActionPreference = 'Stop'

function Test-RecipientAddress {
    param([string]$Address)
    return ($Address -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.PSObject.Properties['externalRecipients']) {
    $config | Add-Member -NotePropertyName externalRecipients -NotePropertyValue @('demo.recipient@example.com') -Force
}

$current = @($config.externalRecipients | Where-Object { $_ } | ForEach-Object { [string]$_ })
switch ($Action) {
    'List' {
        Write-Host '=== External Recipients ===' -ForegroundColor Cyan
        if ($current.Count -eq 0) { Write-Host 'No external recipients configured.' -ForegroundColor Yellow }
        else { $current | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" } }
        return
    }
    'Add' {
        if (-not $Recipient -or $Recipient.Count -eq 0) { throw 'Use -Recipient to add one or more email addresses.' }
        foreach ($item in $Recipient) {
            if (-not (Test-RecipientAddress -Address $item)) { throw "Invalid email address: $item" }
            if ($current -notcontains $item) { $current += $item }
        }
    }
    'Remove' {
        if (-not $Recipient -or $Recipient.Count -eq 0) { throw 'Use -Recipient to remove one or more email addresses.' }
        $current = @($current | Where-Object { $Recipient -notcontains $_ })
    }
    'Clear' {
        $current = @()
    }
}

$config.externalRecipients = @($current | Sort-Object -Unique)
$config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $ConfigPath -Encoding utf8

Write-Host '=== External Recipients Updated ===' -ForegroundColor Cyan
if ($config.externalRecipients.Count -eq 0) {
    Write-Host 'No external recipients configured.' -ForegroundColor Yellow
} else {
    $config.externalRecipients | ForEach-Object { Write-Host "  $_" }
}
Write-Host ''
Write-Host 'Re-run Step 9 or Deploy-BrowserAgentScheduledJobs.ps1 to update Container Apps Job environment variables.' -ForegroundColor Yellow
