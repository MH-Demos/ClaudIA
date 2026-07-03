<#
.SYNOPSIS
    Assembles modules\Invoke-AgentRunbook.ps1 from its source parts.
.DESCRIPTION
    The runbook MUST ship as a single file (the Azure Automation sandbox cannot
    dot-source repo files), but it is EDITED as small source parts under
    modules\runbook\NN-*.ps1. This script concatenates the parts in file-name
    order into the committed artifact modules\Invoke-AgentRunbook.ps1.

    WORKFLOW:
      1. Edit the part file(s) under modules\runbook\  (NEVER edit
         modules\Invoke-AgentRunbook.ps1 directly - it is generated).
      2. Run:  .\tools\Build-Runbook.ps1
      3. Run the net:  .\tests\Invoke-StaticChecks.ps1  (its freshness check
         fails if the artifact does not match the parts).
      4. Commit parts + regenerated artifact together.

    Deploy-Runbook.ps1 (Step 5) and tools\Publish-RunbookOnly.ps1 keep reading
    the artifact and are unaffected by this build step.
.PARAMETER Check
    Do not write anything; exit 0 if the committed artifact already matches the
    assembled parts, 1 otherwise (used by tests\Invoke-StaticChecks.ps1).
#>
[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$partsDir = Join-Path $repoRoot 'modules\runbook'
$artifact = Join-Path $repoRoot 'modules\Invoke-AgentRunbook.ps1'

$parts = @(Get-ChildItem -LiteralPath $partsDir -Filter '*.ps1' -File | Sort-Object Name)
if ($parts.Count -eq 0) { throw "No runbook source parts found under $partsDir" }

$assembled = New-Object System.Collections.Generic.List[string]
foreach ($p in $parts) {
    $assembled.AddRange([System.IO.File]::ReadAllLines($p.FullName))
}

# Parse gate: never emit (or accept) an artifact that does not parse.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(($assembled -join "`r`n"), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "[FAIL] assembled runbook does not parse: L$($parseErrors[0].Extent.StartLineNumber) $($parseErrors[0].Message)" -ForegroundColor Red
    exit 1
}

$current = if (Test-Path -LiteralPath $artifact) { [System.IO.File]::ReadAllLines($artifact) } else { @() }
$upToDate = ($current.Count -eq $assembled.Count)
if ($upToDate) {
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ($current[$i] -cne $assembled[$i]) { $upToDate = $false; break }
    }
}

if ($Check) {
    if ($upToDate) {
        Write-Host "[OK] modules\Invoke-AgentRunbook.ps1 is up to date with modules\runbook\ ($($parts.Count) parts, $($assembled.Count) lines)" -ForegroundColor Green
        exit 0
    }
    Write-Host "[STALE] modules\Invoke-AgentRunbook.ps1 does not match modules\runbook\ - run tools\Build-Runbook.ps1" -ForegroundColor Red
    exit 1
}

if ($upToDate) {
    Write-Host "[OK] artifact already up to date ($($assembled.Count) lines from $($parts.Count) parts)" -ForegroundColor Green
    exit 0
}
[System.IO.File]::WriteAllLines($artifact, $assembled)
Write-Host "[BUILT] modules\Invoke-AgentRunbook.ps1 regenerated: $($assembled.Count) lines from $($parts.Count) parts" -ForegroundColor Green
exit 0
