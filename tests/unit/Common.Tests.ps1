<#
.SYNOPSIS
    Pester 5 unit tests for the pure functions of modules\Common.ps1.
.DESCRIPTION
    Offline, no tenant, no az calls (az-dependent paths are mocked).
    Run directly:   Invoke-Pester -Path tests\unit
    Or via the net: tests\Invoke-StaticChecks.ps1 (auto-runs when Pester 5+ is installed)
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules\Common.ps1')
}

Describe 'Get-AgentUpn' {
    It 'builds sam@domain for a plain sam' {
        Get-AgentUpn -Agent @{ sam = 'alice.moreau' } -Domain 'corp.lab' | Should -Be 'alice.moreau@corp.lab'
    }
    It 'returns sam unchanged when it already contains @' {
        Get-AgentUpn -Agent @{ sam = 'gina@direct.dom' } -Domain 'corp.lab' | Should -Be 'gina@direct.dom'
    }
    It 'returns sam alone when domain is blank' {
        Get-AgentUpn -Agent @{ sam = 'bob' } -Domain '' | Should -Be 'bob'
    }
    It 'prefers userPrincipalName over sam when domain is real' {
        Get-AgentUpn -Agent @{ sam = 'x'; userPrincipalName = 'emily@real-tenant.org' } -Domain 'corp.lab' |
            Should -Be 'emily@real-tenant.org'
    }
    It 'ignores userPrincipalName with placeholder domain contoso.example' {
        Get-AgentUpn -Agent @{ sam = 'frank'; userPrincipalName = 'frank@contoso.example' } -Domain 'corp.lab' |
            Should -Be 'frank@corp.lab'
    }
    It 'ignores placeholder example.com and example.test domains' {
        Get-AgentUpn -Agent @{ sam = 'a'; userPrincipalName = 'a@example.com' } -Domain 'd.io' | Should -Be 'a@d.io'
        Get-AgentUpn -Agent @{ sam = 'b'; upn = 'b@example.test' } -Domain 'd.io' | Should -Be 'b@d.io'
    }
    It 'falls back to the upn property when userPrincipalName is absent' {
        Get-AgentUpn -Agent @{ sam = 'x'; upn = 'diego@lab.example.org' } -Domain 'corp.lab' |
            Should -Be 'diego@lab.example.org'
    }
}

Describe 'Get-AgentSecretName' {
    It 'lowercases and keeps the local part only' {
        Get-AgentSecretName -Agent @{ sam = 'Bob.MARTIN' } -Domain 'corp.lab' | Should -Be 'bob-martin'
    }
    It 'replaces forbidden chars with dashes and collapses runs' {
        Get-AgentSecretName -Agent @{ sam = 'carla_x' } -Domain 'corp.lab' | Should -Be 'carla-x'
        Get-AgentSecretName -Agent @{ sam = 'a..__b' } -Domain 'corp.lab' | Should -Be 'a-b'
    }
    It 'trims leading and trailing dashes' {
        Get-AgentSecretName -Agent @{ sam = '.edge.' } -Domain 'corp.lab' | Should -Be 'edge'
    }
    It 'derives the name from the resolved UPN, not raw sam' {
        Get-AgentSecretName -Agent @{ sam = 'x'; userPrincipalName = 'Emily.J@real.org' } -Domain 'corp.lab' |
            Should -Be 'emily-j'
    }
}

Describe 'Get-KeyVaultName' {
    It 'returns the explicit keyVaultName when set' {
        $cfg = [pscustomobject]@{
            tenant = [pscustomobject]@{ subscriptionId = 'sub-1' }
            infrastructure = [pscustomobject]@{ resourceGroup = 'rg-x'; keyVaultName = 'kv-explicit' }
        }
        Get-KeyVaultName -Config $cfg | Should -Be 'kv-explicit'
    }
    It 'derives a deterministic kv name from sub + rg' {
        $cfg = [pscustomobject]@{
            tenant = [pscustomobject]@{ subscriptionId = '11111111-1111-1111-1111-111111111111' }
            infrastructure = [pscustomobject]@{ resourceGroup = 'rg-claudia-lab'; keyVaultName = '' }
        }
        $a = Get-KeyVaultName -Config $cfg
        $b = Get-KeyVaultName -Config $cfg
        $a | Should -Be $b
        $a | Should -Match '^kv[a-z0-9]{1,11}[0-9a-f]{8}$'
    }
    It 'caps the rg-derived base at 11 chars (Key Vault 24-char limit)' {
        $cfg = [pscustomobject]@{
            tenant = [pscustomobject]@{ subscriptionId = 's' }
            infrastructure = [pscustomobject]@{ resourceGroup = 'rg-very-long-resource-group-name-here'; keyVaultName = $null }
        }
        (Get-KeyVaultName -Config $cfg).Length | Should -BeLessOrEqual 24
    }
}

Describe 'Get-AAGlobalSuffix' {
    It 'is deterministic for the same inputs' {
        (Get-AAGlobalSuffix -SubscriptionId 'sub' -ResourceGroup 'rg') |
            Should -Be (Get-AAGlobalSuffix -SubscriptionId 'sub' -ResourceGroup 'rg')
    }
    It 'is 8 lowercase hex chars' {
        Get-AAGlobalSuffix -SubscriptionId 'sub' -ResourceGroup 'rg' | Should -Match '^[0-9a-f]{8}$'
    }
    It 'changes when the salt changes' {
        (Get-AAGlobalSuffix -SubscriptionId 'sub' -ResourceGroup 'rg' -Salt 'oai') |
            Should -Not -Be (Get-AAGlobalSuffix -SubscriptionId 'sub' -ResourceGroup 'rg' -Salt 'st')
    }
}

Describe 'Set-AAObjectProperty' {
    It 'updates an existing property' {
        $o = [pscustomobject]@{ name = 'old' }
        Set-AAObjectProperty -Object $o -Name 'name' -Value 'new'
        $o.name | Should -Be 'new'
    }
    It 'adds a missing property' {
        $o = [pscustomobject]@{ }
        Set-AAObjectProperty -Object $o -Name 'added' -Value 42
        $o.added | Should -Be 42
    }
}

Describe 'Set-AAInfrastructureDefaults' {
    It 'fills blank names deterministically and keeps explicit values' {
        $cfg = [pscustomobject]@{
            tenant = [pscustomobject]@{ subscriptionId = 'sub-1' }
            infrastructure = [pscustomobject]@{
                resourceGroup = 'rg-claudia-lab'
                automationAccountName = ''
                openAiAccountName = ''
                keyVaultName = 'kv-keep-me'
            }
        }
        $out = Set-AAInfrastructureDefaults -Config $cfg
        $out.infrastructure.automationAccountName | Should -Be 'aa-claudia-lab'
        $out.infrastructure.openAiAccountName | Should -Match '^oai-claudia-[0-9a-f]{8}$'
        $out.infrastructure.keyVaultName | Should -Be 'kv-keep-me'
    }
    It 'mirrors keyVaultName into a blank adx section' {
        $cfg = [pscustomobject]@{
            tenant = [pscustomobject]@{ subscriptionId = 'sub-1' }
            infrastructure = [pscustomobject]@{ resourceGroup = 'rg-x'; automationAccountName = 'aa'; openAiAccountName = 'oai'; keyVaultName = 'kv-main' }
            adx = [pscustomobject]@{ keyVaultName = '' }
        }
        (Set-AAInfrastructureDefaults -Config $cfg).adx.keyVaultName | Should -Be 'kv-main'
    }
}

Describe 'ConvertTo-AATenantConfigKey' {
    It 'takes the first DNS label' {
        ConvertTo-AATenantConfigKey -Domain 'contoso.onmicrosoft.com' | Should -Be 'contoso'
    }
    It 'strips characters invalid in file names' {
        ConvertTo-AATenantConfigKey -Domain 'we!rd$name.org' | Should -Be 'werdname'
    }
    It 'returns empty string for missing domain' {
        ConvertTo-AATenantConfigKey -Domain '' | Should -Be ''
        ConvertTo-AATenantConfigKey | Should -Be ''
    }
}

Describe 'Resolve-AATenantConfigPath' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("claudia-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'config\tenants') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:root 'config\agents.json') -Value '{}'
        $script:oldTenantEnv = $env:CLAUDIA_TENANT
        $env:CLAUDIA_TENANT = $null
        # Never touch the real az login during unit tests.
        Mock Invoke-AAAzCommand { $null }
    }
    AfterEach {
        if ($null -ne $script:oldTenantEnv) { $env:CLAUDIA_TENANT = $script:oldTenantEnv }
        else { Remove-Item Env:\CLAUDIA_TENANT -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'always honors an explicit path' {
        Resolve-AATenantConfigPath -RepoRoot $script:root -ExplicitPath 'C:\x\y.json' -Quiet | Should -Be 'C:\x\y.json'
    }
    It 'selects the per-tenant file when CLAUDIA_TENANT matches an existing file' {
        Set-Content -LiteralPath (Join-Path $script:root 'config\tenants\fabrikam.json') -Value '{}'
        $env:CLAUDIA_TENANT = 'fabrikam.onmicrosoft.com'
        Resolve-AATenantConfigPath -RepoRoot $script:root -Quiet |
            Should -Be (Join-Path $script:root 'config\tenants\fabrikam.json')
    }
    It 'falls back to legacy agents.json when the per-tenant file does not exist' {
        $env:CLAUDIA_TENANT = 'missing.onmicrosoft.com'
        Resolve-AATenantConfigPath -RepoRoot $script:root -Quiet |
            Should -Be (Join-Path $script:root 'config\agents.json')
    }
    It 'auto-detects the tenant from the az login domain' {
        Set-Content -LiteralPath (Join-Path $script:root 'config\tenants\autodetected.json') -Value '{}'
        Mock Invoke-AAAzCommand { 'admin@autodetected.onmicrosoft.com' }
        Resolve-AATenantConfigPath -RepoRoot $script:root -Quiet |
            Should -Be (Join-Path $script:root 'config\tenants\autodetected.json')
    }
}

Describe 'New-AALabPassword' {
    It 'produces the requested length' {
        (New-AALabPassword -Length 20).Length | Should -Be 20
        (New-AALabPassword -Length 32).Length | Should -Be 32
    }
    It 'contains at least one char of each class' {
        $p = New-AALabPassword -Length 20
        $p | Should -Match '[A-Z]'
        $p | Should -Match '[a-z]'
        $p | Should -Match '[0-9]'
        $p | Should -Match '[!#$%]'
    }
    It 'uses only the unambiguous allowed alphabet' {
        # No I, O, l, 0, 1 (visually ambiguous chars are excluded from the sets)
        New-AALabPassword -Length 64 | Should -Match '^[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#$%]+$'
    }
    It 'does not repeat across calls' {
        New-AALabPassword | Should -Not -Be (New-AALabPassword)
    }
}

Describe 'Save-AAJsonAtomic' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ("claudia-json-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:target = Join-Path $script:dir 'out.json'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'writes valid JSON and leaves no temp file' {
        Save-AAJsonAtomic -Path $script:target -Json '{"a": 1}'
        (Get-Content -LiteralPath $script:target -Raw | ConvertFrom-Json).a | Should -Be 1
        Test-Path "$script:target.tmp" | Should -BeFalse
    }
    It 'overwrites an existing file atomically' {
        Set-Content -LiteralPath $script:target -Value '{"old": true}'
        Save-AAJsonAtomic -Path $script:target -Json '{"new": true}'
        (Get-Content -LiteralPath $script:target -Raw | ConvertFrom-Json).new | Should -BeTrue
    }
    It 'refuses to overwrite the target with invalid JSON and cleans the temp file' {
        Set-Content -LiteralPath $script:target -Value '{"precious": true}'
        { Save-AAJsonAtomic -Path $script:target -Json '{not json' } | Should -Throw
        (Get-Content -LiteralPath $script:target -Raw | ConvertFrom-Json).precious | Should -BeTrue
        Test-Path "$script:target.tmp" | Should -BeFalse
    }
}

Describe 'Sync-AAInstallationDefinitionsWithTenant' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("claudia-sync-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'config\tenants') -Force | Out-Null
        $script:active = Join-Path $script:root 'config\Installation_definitions.json'
        $script:cfgA = Join-Path $script:root 'config\tenants\alpha.json'
        $script:cfgB = Join-Path $script:root 'config\tenants\beta.json'
        Set-Content $script:cfgA -Value '{}'
        Set-Content $script:cfgB -Value '{}'
        # helper to fabricate a state file owned by a tenant
        $script:mkState = { param($Domain) '{"tenant": {"domain": "' + $Domain + '"}, "steps": {"marker": "' + $Domain + '"}}' }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'is a no-op in legacy single-tenant mode (config not under tenants dir)' {
        Set-Content $script:active -Value (& $script:mkState 'alpha.onmicrosoft.com')
        Sync-AAInstallationDefinitionsWithTenant -RepoRoot $script:root -ConfigPath (Join-Path $script:root 'config\agents.json') -Quiet
        (Get-Content $script:active -Raw | ConvertFrom-Json).tenant.domain | Should -Be 'alpha.onmicrosoft.com'
        Test-Path (Join-Path $script:root 'config\tenants\alpha.definitions.json') | Should -BeFalse
    }
    It 'refreshes the archive when the active state already belongs to the resolved tenant' {
        Set-Content $script:active -Value (& $script:mkState 'alpha.onmicrosoft.com')
        Sync-AAInstallationDefinitionsWithTenant -RepoRoot $script:root -ConfigPath $script:cfgA -Quiet
        (Get-Content (Join-Path $script:root 'config\tenants\alpha.definitions.json') -Raw | ConvertFrom-Json).steps.marker |
            Should -Be 'alpha.onmicrosoft.com'
        (Get-Content $script:active -Raw | ConvertFrom-Json).tenant.domain | Should -Be 'alpha.onmicrosoft.com'
    }
    It 'archives tenant A and restores tenant B on switch' {
        Set-Content $script:active -Value (& $script:mkState 'alpha.onmicrosoft.com')
        Set-Content (Join-Path $script:root 'config\tenants\beta.definitions.json') -Value (& $script:mkState 'beta.onmicrosoft.com')
        Sync-AAInstallationDefinitionsWithTenant -RepoRoot $script:root -ConfigPath $script:cfgB -Quiet
        (Get-Content $script:active -Raw | ConvertFrom-Json).tenant.domain | Should -Be 'beta.onmicrosoft.com'
        (Get-Content (Join-Path $script:root 'config\tenants\alpha.definitions.json') -Raw | ConvertFrom-Json).tenant.domain |
            Should -Be 'alpha.onmicrosoft.com'
    }
    It 'archives tenant A and starts fresh when the resolved tenant has no archive' {
        Set-Content $script:active -Value (& $script:mkState 'alpha.onmicrosoft.com')
        Sync-AAInstallationDefinitionsWithTenant -RepoRoot $script:root -ConfigPath $script:cfgB -Quiet
        Test-Path $script:active | Should -BeFalse
        Test-Path (Join-Path $script:root 'config\tenants\alpha.definitions.json') | Should -BeTrue
    }
    It 'preserves unowned (template) state under backups instead of losing it' {
        Set-Content $script:active -Value '{"tenant": {"domain": ""}, "steps": {"leftover": true}}'
        Set-Content (Join-Path $script:root 'config\tenants\alpha.definitions.json') -Value (& $script:mkState 'alpha.onmicrosoft.com')
        Sync-AAInstallationDefinitionsWithTenant -RepoRoot $script:root -ConfigPath $script:cfgA -Quiet
        (Get-Content $script:active -Raw | ConvertFrom-Json).tenant.domain | Should -Be 'alpha.onmicrosoft.com'
        @(Get-ChildItem (Join-Path $script:root 'config\backups') -Filter 'Installation_definitions.unowned-*.json').Count | Should -Be 1
    }
}

Describe 'Initialize-AAInstallationDefinitions tenant guard' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("claudia-guard-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'config') -Force | Out-Null
        $script:defs = Join-Path $script:root 'config\Installation_definitions.json'
        $script:mkConfig = { param($Domain) [pscustomobject]@{
            tenant = [pscustomobject]@{ domain = $Domain; tenantId = 't'; subscriptionId = 's'; location = 'l'; country = 'US' }
            infrastructure = [pscustomobject]@{ resourceGroup = 'rg'; automationAccountName = 'aa'; openAiAccountName = 'oai'; openAiModel = 'm'; openAiModelVersion = 'v'; openAiImageModel = 'im'; openAiImageModelVersion = 'iv'; openAiTpm = 1; fabricEnabled = $false; keyVaultName = 'kv' }
            agents = @()
        } }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        $script:AAInstallationDefinitions = $null
    }
    It 'accepts a re-run for the same tenant' {
        Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'alpha.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z'
        { Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'alpha.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z2' } |
            Should -Not -Throw
    }
    It 'refuses a template config over real tenant state' {
        Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'alpha.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z'
        { Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig '') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z2' } |
            Should -Throw '*no tenant identity*'
    }
    It 'refuses another tenant''s config over existing state' {
        Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'alpha.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z'
        { Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'beta.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z2' } |
            Should -Throw '*Refusing to overwrite*'
    }
    It 'allows -Fresh to start over regardless of owner' {
        Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'alpha.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z'
        { Initialize-AAInstallationDefinitions -Path $script:defs -Config (& $script:mkConfig 'beta.onmicrosoft.com') -ConfigPath 'x' -RunLogPath 'y' -RunStamp 'z2' -Fresh } |
            Should -Not -Throw
    }
}
