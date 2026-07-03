<#
.SYNOPSIS
    ClaudIA static verification net. Fast (< 30s), offline, read-only.
.DESCRIPTION
    Single green/red command to run after ANY code change, before commit:

        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-StaticChecks.ps1

    Checks:
      1. PARSE      - every .ps1 parses clean (PowerShell 5.1 AST parser).
      2. ASCII      - no NEW non-ASCII characters in .ps1 files (Azure Automation
                      and PS 5.1 choke on smart quotes/em-dashes). Known legacy
                      lines are allowlisted with their exact counts.
      3. JSON       - every config/*.json parses; agents.json has its required
                      top-level sections; every locale file has sitReference and
                      fileTypes.
      4. DRIFT      - Get-AgentUpn / Get-AgentSecretName are duplicated in
                      Invoke-AgentRunbook.ps1 (AA sandbox cannot dot-source
                      Common.ps1). Both copies are executed against a probe
                      matrix and must produce identical results.
      5. UNIT       - Pester 5 unit tests (tests\unit\*.Tests.ps1) on the pure
                      functions of Common.ps1. Soft-skipped when Pester 5+ is
                      not installed.
      6. NODE       - opt-in (-IncludeNode): BrowserAgents content pack
                      validation. Opt-in because it REGENERATES
                      synthetic-m365-purview-pack/content-pack.json (side effect).

    Exit code 0 = all green, 1 = at least one failure.
.PARAMETER IncludeNode
    Also run 'npm run content:validate' in BrowserAgents (writes content-pack.json).
.PARAMETER ShowDetail
    Print every file checked, not only failures.
#>
[CmdletBinding()]
param(
    [switch]$IncludeNode,
    [switch]$ShowDetail
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$failures = New-Object System.Collections.Generic.List[string]
$checksRun = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Write-CheckResult {
    param([string]$Check, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host "  [PASS] $Check" -ForegroundColor Green
        if ($Detail -and $ShowDetail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    } else {
        Write-Host "  [FAIL] $Check" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
        $script:failures.Add($Check)
    }
    $script:checksRun++
}

Write-Host ""
Write-Host "=== ClaudIA Static Checks ===" -ForegroundColor Cyan
Write-Host "  Root: $repoRoot" -ForegroundColor DarkGray

# Shared file inventory (exclude node_modules and generated/report folders)
$psFiles = @(Get-ChildItem -Path $repoRoot -Recurse -Include *.ps1 -File |
    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\playwright-report\\|\\test-results\\' })

# =============================================================================
# CHECK 1: PARSE - all .ps1 files parse without errors
# =============================================================================
Write-Host ""
Write-Host "--- 1. PowerShell parse (AST) ---" -ForegroundColor Cyan
# Files declaring '#Requires -Version 7' use PS7-only syntax (e.g. '??') that the
# 5.1 parser rejects by design; they are parsed with pwsh when available.
$ps7Files = @()
$ps51Files = @()
foreach ($f in $psFiles) {
    $head = (Get-Content -LiteralPath $f.FullName -TotalCount 60) -join "`n"
    if ($head -match '#Requires\s+-Version\s+7') { $ps7Files += $f } else { $ps51Files += $f }
}
$parseFailures = @()
foreach ($f in $ps51Files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $first = $errors[0]
        $parseFailures += "$($f.FullName.Replace($repoRoot + '\', '')) (L$($first.Extent.StartLineNumber): $($first.Message))"
    }
}
Write-CheckResult -Check "Parse (PS 5.1): $($ps51Files.Count) .ps1 files" -Ok ($parseFailures.Count -eq 0) `
    -Detail $(if ($parseFailures.Count -gt 0) { $parseFailures -join '; ' } else { 'no parse errors' })

if ($ps7Files.Count -gt 0) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $ps7Failures = @()
        foreach ($f in $ps7Files) {
            $out = & pwsh -NoProfile -Command "`$e=`$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$($f.FullName)', [ref]`$null, [ref]`$e); `$e.Count"
            if ([int]$out -gt 0) { $ps7Failures += $f.FullName.Replace($repoRoot + '\', '') }
        }
        Write-CheckResult -Check "Parse (PS 7): $($ps7Files.Count) '#Requires -Version 7' files" -Ok ($ps7Failures.Count -eq 0) `
            -Detail $(if ($ps7Failures.Count -gt 0) { $ps7Failures -join '; ' } else { ($ps7Files | ForEach-Object Name) -join ', ' })
    } else {
        Write-CheckResult -Check "Parse (PS 7): $($ps7Files.Count) files skipped" -Ok $true -Detail 'pwsh not installed on this machine'
    }
}

# =============================================================================
# CHECK 2: ASCII - no new non-ASCII lines in .ps1 (allowlist for legacy lines)
# =============================================================================
Write-Host ""
Write-Host "--- 2. ASCII purity (.ps1) ---" -ForegroundColor Cyan
# Known legacy non-ASCII lines (comments/data written before the ASCII rule).
# Key = repo-relative path, value = max allowed count of non-ASCII LINES.
# Reducing a count here is welcome; increasing one is a failure.
$nonAsciiAllow = @{
    'modules\Configure-DLP.ps1'                          = 2
    'modules\Deploy-Runbook.ps1'                         = 1
    'modules\Provision-M365Collaboration.ps1'            = 1
    'tools\Initialize-StorylineEntraUsers.ps1'           = 1
    'tools\Publish-ActivityStoryMapAssets.ps1'           = 1
    'tools\Update-ActivityStoryMapCharacterProfiles.ps1' = 1
}
$asciiFailures = @()
foreach ($f in $psFiles) {
    $rel = $f.FullName.Replace($repoRoot + '\', '')
    $count = @(Select-String -Path $f.FullName -Pattern '[^\x00-\x7F]').Count
    $allowed = if ($nonAsciiAllow.ContainsKey($rel)) { $nonAsciiAllow[$rel] } else { 0 }
    if ($count -gt $allowed) {
        $lines = (Select-String -Path $f.FullName -Pattern '[^\x00-\x7F]' | Select-Object -First 3 | ForEach-Object LineNumber) -join ','
        $asciiFailures += "$rel has $count non-ASCII line(s), allowed $allowed (lines $lines)"
    }
}
Write-CheckResult -Check 'ASCII: no new non-ASCII characters' -Ok ($asciiFailures.Count -eq 0) `
    -Detail $(if ($asciiFailures.Count -gt 0) { $asciiFailures -join '; ' } else { "$($nonAsciiAllow.Count) legacy files allowlisted" })

# =============================================================================
# CHECK 3: JSON - config files parse and have required shape
# =============================================================================
Write-Host ""
Write-Host "--- 3. JSON config validity ---" -ForegroundColor Cyan
$jsonFailures = @()
$configJson = @(Get-ChildItem -Path (Join-Path $repoRoot 'config') -Recurse -Include *.json -File |
    Where-Object { $_.FullName -notmatch '\\backups\\' })
foreach ($f in $configJson) {
    $rel = $f.FullName.Replace($repoRoot + '\', '')
    try {
        $null = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $jsonFailures += "$rel does not parse: $($_.Exception.Message)"
    }
}
Write-CheckResult -Check "JSON parse: $($configJson.Count) files under config\" -Ok ($jsonFailures.Count -eq 0) `
    -Detail $(if ($jsonFailures.Count -gt 0) { $jsonFailures -join '; ' } else { 'all parse' })

# agents.json required sections
$agentsShapeFailures = @()
try {
    $agentsCfg = Get-Content -LiteralPath (Join-Path $repoRoot 'config\agents.json') -Raw | ConvertFrom-Json
    foreach ($key in @('tenant', 'infrastructure', 'agents', 'schedules', 'features')) {
        if (-not $agentsCfg.PSObject.Properties[$key]) { $agentsShapeFailures += "agents.json is missing top-level section '$key'" }
    }
    if ($agentsCfg.agents -and @($agentsCfg.agents).Count -eq 0) { $agentsShapeFailures += 'agents.json has an empty agents[] array' }
} catch {
    $agentsShapeFailures += "agents.json unreadable: $($_.Exception.Message)"
}
Write-CheckResult -Check 'agents.json required sections' -Ok ($agentsShapeFailures.Count -eq 0) `
    -Detail $(if ($agentsShapeFailures.Count -gt 0) { $agentsShapeFailures -join '; ' } else { 'tenant/infrastructure/agents/schedules/features present' })

# Locale files must carry the fields the runbook depends on
$localeFailures = @()
$localeFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'config\locales') -Filter *.json -File -ErrorAction SilentlyContinue)
foreach ($f in $localeFiles) {
    try {
        $loc = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$loc.sitReference)) { $localeFailures += "$($f.Name): sitReference missing/empty" }
        if (-not $loc.fileTypes -or @($loc.fileTypes.PSObject.Properties).Count -eq 0) { $localeFailures += "$($f.Name): fileTypes missing/empty" }
        if ([string]::IsNullOrWhiteSpace([string]$loc.country)) { $localeFailures += "$($f.Name): country missing" }
    } catch {
        $localeFailures += "$($f.Name): unreadable"
    }
}
Write-CheckResult -Check "Locales: $($localeFiles.Count) files have country+sitReference+fileTypes" -Ok ($localeFailures.Count -eq 0) `
    -Detail $(if ($localeFailures.Count -gt 0) { $localeFailures -join '; ' } else { ($localeFiles | ForEach-Object BaseName) -join ', ' })

# =============================================================================
# CHECK 4: DRIFT - duplicated runbook helpers behave like Common.ps1
# =============================================================================
Write-Host ""
Write-Host "--- 4. Runbook/Common helper drift (behavioral) ---" -ForegroundColor Cyan
$driftFailures = @()
try {
    $probeAgents = @(
        @{ sam = 'alice.moreau' },
        @{ sam = 'Bob.MARTIN' },
        @{ sam = 'carla_x' },
        @{ sam = 'diego.martinez'; upn = 'diego.martinez@lab.example.org' },
        @{ sam = 'emily'; userPrincipalName = 'emily.johnson@real-tenant.org' },
        @{ sam = 'frank'; userPrincipalName = 'frank@contoso.example' },
        @{ sam = 'gina@direct.dom' }
    )
    $probeDomain = 'unit.test'

    $implementations = @{}
    foreach ($src in @('modules\Common.ps1', 'modules\Invoke-AgentRunbook.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $src), [ref]$tokens, [ref]$errors)
        $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $upnFn = $defs | Where-Object Name -eq 'Get-AgentUpn' | Select-Object -First 1
        $secretFn = $defs | Where-Object Name -eq 'Get-AgentSecretName' | Select-Object -First 1
        if (-not $upnFn -or -not $secretFn) {
            $driftFailures += "$src no longer defines Get-AgentUpn/Get-AgentSecretName (update tests\Invoke-StaticChecks.ps1 if intentional)"
            continue
        }
        # Both param names differ between copies, so invoke positionally.
        $body = $upnFn.Extent.Text + "`n" + $secretFn.Extent.Text + "`n" +
            '"{0}|{1}" -f (Get-AgentUpn $args[0] $args[1]), (Get-AgentSecretName $args[0] $args[1])'
        $implementations[$src] = [scriptblock]::Create($body)
    }
    if ($driftFailures.Count -eq 0) {
        for ($i = 0; $i -lt $probeAgents.Count; $i++) {
            $common  = & $implementations['modules\Common.ps1'] $probeAgents[$i] $probeDomain
            $runbook = & $implementations['modules\Invoke-AgentRunbook.ps1'] $probeAgents[$i] $probeDomain
            if ($common -ne $runbook) {
                $driftFailures += "probe '$($probeAgents[$i].sam)': Common='$common' vs Runbook='$runbook'"
            }
        }
    }
} catch {
    $driftFailures += "drift check crashed: $($_.Exception.Message)"
}
Write-CheckResult -Check 'Helper drift: Get-AgentUpn/Get-AgentSecretName' -Ok ($driftFailures.Count -eq 0) `
    -Detail $(if ($driftFailures.Count -gt 0) { $driftFailures -join '; ' } else { "$($probeAgents.Count) probes identical across both copies" })

# =============================================================================
# CHECK 5: UNIT - Pester unit tests on Common.ps1 pure functions
# =============================================================================
Write-Host ""
Write-Host "--- 5. Unit tests (Pester) ---" -ForegroundColor Cyan
$pester5 = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if ($pester5) {
    try {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = Join-Path $PSScriptRoot 'unit'
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'None'
        $result = Invoke-Pester -Configuration $pesterConfig
        $unitOk = ($result.FailedCount -eq 0 -and $result.TotalCount -gt 0)
        Write-CheckResult -Check "Pester: $($result.PassedCount)/$($result.TotalCount) unit tests" -Ok $unitOk `
            -Detail $(if (-not $unitOk) { ($result.Failed | ForEach-Object { $_.ExpandedPath }) -join '; ' } else { "$([int]$result.Duration.TotalSeconds)s" })
    } catch {
        Write-CheckResult -Check 'Pester: unit tests' -Ok $false -Detail "Pester run crashed: $($_.Exception.Message)"
    }
} else {
    Write-CheckResult -Check 'Pester: unit tests skipped' -Ok $true `
        -Detail 'Pester 5+ not installed (pwsh: Save-Module Pester -Path <5.1 module dir>); unit layer not enforced on this machine'
}

# =============================================================================
# CHECK 6 (opt-in): Node content pack validation
# =============================================================================
if ($IncludeNode) {
    Write-Host ""
    Write-Host "--- 6. BrowserAgents content pack (npm) ---" -ForegroundColor Cyan
    $baDir = Join-Path $repoRoot 'BrowserAgents'
    if (Test-Path (Join-Path $baDir 'node_modules')) {
        Push-Location $baDir
        try {
            $null = & cmd /c "npm run content:validate 2>&1"
            Write-CheckResult -Check 'npm run content:validate' -Ok ($LASTEXITCODE -eq 0) `
                -Detail "exit code $LASTEXITCODE (NOTE: regenerates synthetic-m365-purview-pack\content-pack.json)"
        } finally {
            Pop-Location
        }
    } else {
        Write-CheckResult -Check 'npm run content:validate' -Ok $true -Detail 'skipped: BrowserAgents\node_modules not installed'
    }
}

# =============================================================================
# SUMMARY
# =============================================================================
$sw.Stop()
Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "=== GREEN: $checksRun check(s) passed in $([int]$sw.Elapsed.TotalSeconds)s ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== RED: $($failures.Count)/$checksRun check(s) FAILED in $([int]$sw.Elapsed.TotalSeconds)s ===" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
