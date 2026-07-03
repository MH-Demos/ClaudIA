# =============================================================================
# ClaudIA installer step (extracted from Install-ClaudIA.ps1).
# DOT-SOURCED by the installer: this file runs in the INSTALLER scope.
# Contract: $installRoot = repo root, $installBoundParams = installer
# $PSBoundParameters. Do NOT use $PSScriptRoot/$PSBoundParameters here.
# =============================================================================
# ============================================================================
# STEP 10: MDCA CLOUD DISCOVERY CONNECTOR (optional)
# ============================================================================
if (Test-AAInstallStep '10') {
    Write-Host "=== Step 10: MDCA Cloud Discovery Connector ===" -ForegroundColor Cyan
    Write-Host "  Stores MDCA portal URL/API token in Key Vault and validates Cloud Discovery API access." -ForegroundColor Gray
    Write-Host "  Required values: MDCA portal URL and API token from Defender for Cloud Apps." -ForegroundColor Gray
    Write-Host ""

    $deployMdca = 'n'
    if (-not $DryRun) {
        $deployMdca = if ($Auto) { 'n' } else { Read-Host "  Configure MDCA Cloud Discovery connector now? (y/N)" }
        if ($deployMdca -in @('y','Y','yes','YES')) {
            $portalUrl = Read-Host "  MDCA portal URL (e.g. https://<tenant>.portal.cloudappsecurity.com)"
            $secureToken = Read-Host "  MDCA API token" -AsSecureString
            $tokenBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
            try {
                $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenBstr)
                $streamNameDefault = "ClaudIA ADX Cloud Discovery"
                $streamName = Read-Host "  MDCA input stream name [$streamNameDefault]"
                if (-not $streamName) { $streamName = $streamNameDefault }
                & (Join-Path $installRoot 'tools\Deploy-MdcaCloudDiscoveryConnector.ps1') `
                    -ConfigPath $ConfigPath `
                    -InstallationDefinitionsPath $installationDefinitionsPath `
                    -PortalUrl $portalUrl `
                    -Token $token `
                    -InputStreamName $streamName `
                    -ProbeUploadUrl
            } finally {
                if ($tokenBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenBstr) }
                $token = $null
            }
        } else {
            Write-Host "  [SKIP] MDCA connector setup skipped." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  [DRY-RUN] Would store MDCA settings in Key Vault and validate Cloud Discovery API access." -ForegroundColor DarkYellow
    }

    Set-AAInstallationStepDefinition -Path $installationDefinitionsPath -Step '10' -Value ([ordered]@{
        activity = 'MDCA Cloud Discovery connector'
        completedAt = (Get-Date).ToString('o')
        dryRun = [bool]$DryRun
        requested = ($deployMdca -in @('y','Y','yes','YES'))
    })
    if ($deployMdca -in @('y','Y','yes','YES')) {
        Set-AADeploymentResult -Step '10' -MainActivity 'MDCA Cloud Discovery connector' -Status 'deployed' -Comments 'MDCA settings stored in Key Vault and API access validated.'
    }
    Write-Host ""
}

