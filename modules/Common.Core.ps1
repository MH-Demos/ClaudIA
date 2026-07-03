# =============================================================================
# Common.Core.ps1 - pure helpers: passwords, identity, naming, object utils
# Split from modules\Common.ps1 (loaded by the Common.ps1 facade - callers
# keep dot-sourcing modules\Common.ps1 and see no difference).
# =============================================================================

function New-AALabPassword {
    # Cryptographically random password with replacement (repeated chars allowed)
    # and at least one char from each class. Get-Random -Count samples WITHOUT
    # replacement and is not a crypto RNG, so it must not be used for passwords.
    param([int]$Length = 20)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!#$%'
    $all = $upper + $lower + $digit + $symbol
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param([string]$Set)
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $Set[[System.BitConverter]::ToUInt32($bytes, 0) % $Set.Length]
        }
        $chars = [System.Collections.Generic.List[char]]::new()
        $chars.Add((& $pick $upper))
        $chars.Add((& $pick $lower))
        $chars.Add((& $pick $digit))
        $chars.Add((& $pick $symbol))
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
        # Fisher-Yates shuffle with the same RNG so class-guaranteed chars are not predictable prefixes
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = [byte[]]::new(4)
            $rng.GetBytes($bytes)
            $j = [System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    } finally {
        $rng.Dispose()
    }
}

function Write-AASecretLine {
    # Shows a secret on screen WITHOUT recording it in the PowerShell transcript:
    # Start-Transcript captures the PowerShell output streams (Write-Host included)
    # but not direct console writes. Falls back to nothing in non-interactive hosts.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Secret
    )
    try {
        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        [Console]::WriteLine("  ${Label}: $Secret")
        [Console]::ResetColor()
        Write-Host "  ${Label}: ******** (shown on screen only; not written to the log)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  ${Label}: ******** (console unavailable; value not displayed)" -ForegroundColor DarkGray
    }
}

function Get-AgentUpn {
    param(
        [Parameter(Mandatory)]$Agent,
        [string]$Domain
    )
    if ($Agent.userPrincipalName) {
        $configuredUpn = [string]$Agent.userPrincipalName
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ($Agent.upn) {
        $configuredUpn = [string]$Agent.upn
        $configuredDomain = ($configuredUpn -split '@')[-1]
        if ($configuredDomain -notin @('contoso.example','example.com','example.test')) {
            return $configuredUpn
        }
    }
    if ("$($Agent.sam)" -match '@') { return [string]$Agent.sam }
    if ([string]::IsNullOrWhiteSpace($Domain)) { return [string]$Agent.sam }
    return "$($Agent.sam)@$Domain"
}

function Get-AgentSecretName {
    param(
        [Parameter(Mandatory)]$Agent,
        [string]$Domain
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

function Get-AAGlobalSuffix {
    # Deterministic 8-char suffix (sub + RG) for globally-unique resource names
    # (Azure OpenAI account, storage). Mirrors Get-KeyVaultName seeding so all
    # derived names for a given (subscription, resourceGroup) stay stable across
    # reruns. ASCII/lowercase only.
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string]$Salt = ''
    )
    $seed = "$SubscriptionId-$ResourceGroup-$Salt"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 8)).ToLowerInvariant()
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

function Write-AALongRunningNotice {
    param([string]$Activity)

    Write-Host "  $Activity can take several minutes. Please be patient while Azure finishes provisioning." -ForegroundColor DarkYellow
}

