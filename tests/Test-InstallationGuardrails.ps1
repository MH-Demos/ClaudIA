<#PSScriptInfo

.VERSION 1.0.0

.GUID 3b6672ae-9ef5-4f8a-bf9e-5d1fc06c8824

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell ConditionalAccess KeyVault Tests

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Validate Conditional Access classification and first-run persona secret decisions.

.RELEASENOTES
Version 1.0.0 adds local unit coverage for installation guardrails.

#>
<#
.SYNOPSIS
    Validate installation guardrails without changing a tenant.
.DESCRIPTION
    Uses synthetic Conditional Access policies and secret states to verify
    classification, idempotent group exclusions, and partial Key Vault repairs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\Common.ps1')

function Assert-AAEqual {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Actual,
        $Expected
    )

    if ($Actual -ne $Expected) {
        throw "$Name failed. Expected '$Expected', got '$Actual'."
    }
}

function Assert-AATrue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Value
    )

    if (-not $Value) { throw "$Name failed." }
}

function New-AATestConditionalAccessPolicy {
    param(
        [string]$Id = ([guid]::NewGuid().ToString()),
        [string]$Name = 'Test policy',
        [string]$State = 'enabled',
        [string[]]$IncludeUsers = @('All'),
        [string[]]$IncludeGroups = @(),
        [string[]]$ExcludeGroups = @(),
        [string[]]$IncludeApplications = @('All'),
        [string[]]$ExcludeApplications = @(),
        [string[]]$IncludeUserActions = @(),
        [string[]]$BuiltInControls = @('mfa'),
        [string[]]$TermsOfUse = @(),
        [string]$AuthenticationStrengthId = ''
    )

    $authenticationStrength = if ($AuthenticationStrengthId) {
        [PSCustomObject]@{ id = $AuthenticationStrengthId; displayName = 'Test strength' }
    } else {
        $null
    }

    return [PSCustomObject]@{
        id = $Id
        displayName = $Name
        state = $State
        templateId = $null
        conditions = [PSCustomObject]@{
            users = [PSCustomObject]@{
                includeUsers = $IncludeUsers
                includeGroups = $IncludeGroups
                excludeUsers = @()
                excludeGroups = $ExcludeGroups
                includeRoles = @()
                excludeRoles = @()
                includeGuestsOrExternalUsers = $null
                excludeGuestsOrExternalUsers = $null
            }
            applications = [PSCustomObject]@{
                includeApplications = $IncludeApplications
                excludeApplications = $ExcludeApplications
                includeUserActions = $IncludeUserActions
                includeAuthenticationContextClassReferences = @()
            }
            locations = [PSCustomObject]@{
                includeLocations = @()
                excludeLocations = @()
            }
            clientAppTypes = @('all')
        }
        grantControls = [PSCustomObject]@{
            operator = 'OR'
            builtInControls = $BuiltInControls
            termsOfUse = $TermsOfUse
            customAuthenticationFactors = @()
            authenticationStrength = $authenticationStrength
        }
        sessionControls = $null
    }
}

$groupId = '11111111-1111-1111-1111-111111111111'
$agentId = '22222222-2222-2222-2222-222222222222'
$agentParentGroupId = '33333333-3333-3333-3333-333333333333'
$graphSpId = '44444444-4444-4444-4444-444444444444'

$grant = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Enabled MFA policy action' $grant.Action 'Exclude'
Assert-AAEqual 'Enabled MFA policy control' $grant.ControlType 'Grant'

$block = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -BuiltInControls @('block')) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Enabled block policy action' $block.Action 'Exclude'
Assert-AAEqual 'Enabled block policy control' $block.ControlType 'Block'

$reportOnly = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -State 'enabledForReportingButNotEnforced') `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Report-only policy action' $reportOnly.Action 'ReportOnly'

$alreadyExcludedPolicy = New-AATestConditionalAccessPolicy -ExcludeGroups @('existing-group', $groupId)
$alreadyExcluded = Get-AAConditionalAccessPolicyAssessment `
    -Policy $alreadyExcludedPolicy -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Existing group exclusion action' $alreadyExcluded.Action 'AlreadyExcluded'

$scopePolicy = New-AATestConditionalAccessPolicy -ExcludeGroups @('existing-group')
$scopePolicy.conditions.users.excludeUsers = @('77777777-7777-7777-7777-777777777777')
$scopePolicy.conditions.users.includeGroups = @('88888888-8888-8888-8888-888888888888')
$scopePolicy.conditions.users.includeRoles = @('99999999-9999-9999-9999-999999999999')
$scopePolicy.conditions.users.includeGuestsOrExternalUsers = [PSCustomObject]@{
    guestOrExternalUserTypes = 'b2bCollaborationGuest'
    externalTenants = [PSCustomObject]@{
        membershipKind = 'all'
    }
}
$usersBody = Get-AAConditionalAccessUsersBody `
    -Users $scopePolicy.conditions.users -ExclusionGroupId $groupId
Assert-AATrue 'Users body preserves includeUsers' (@($usersBody.includeUsers) -contains 'All')
Assert-AATrue 'Users body preserves includeGroups' (@($usersBody.includeGroups) -contains '88888888-8888-8888-8888-888888888888')
Assert-AATrue 'Users body preserves excludeUsers' (@($usersBody.excludeUsers) -contains '77777777-7777-7777-7777-777777777777')
Assert-AATrue 'Users body preserves includeRoles' (@($usersBody.includeRoles) -contains '99999999-9999-9999-9999-999999999999')
Assert-AATrue 'Users body preserves prior excludeGroups' (@($usersBody.excludeGroups) -contains 'existing-group')
Assert-AATrue 'Users body adds dedicated excludeGroup' (@($usersBody.excludeGroups) -contains $groupId)
Assert-AATrue 'Users body preserves guest scope' ($null -ne $usersBody.includeGuestsOrExternalUsers)
Assert-AAEqual 'Source policy remains unchanged' @($scopePolicy.conditions.users.excludeGroups).Count 1

$verifiedUsers = $usersBody | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$noScopeDifferences = @(Get-AAConditionalAccessUsersDifferences -Expected $usersBody -Actual $verifiedUsers)
Assert-AAEqual 'Unchanged users scope verification' $noScopeDifferences.Count 0
$verifiedUsers.includeUsers = @()
$scopeDifferences = @(Get-AAConditionalAccessUsersDifferences -Expected $usersBody -Actual $verifiedUsers)
Assert-AATrue 'Dropped includeUsers is detected' ($scopeDifferences -contains 'includeUsers')

$scopePolicy.conditions.locations.includeLocations = @('All')
$scopePolicy.conditions.locations.excludeLocations = @('AllTrusted')
$conditionsBody = Get-AAConditionalAccessConditionsBody `
    -Conditions $scopePolicy.conditions -UsersBody $usersBody
$verifiedConditions = $conditionsBody | ConvertTo-Json -Depth 50 | ConvertFrom-Json
$noConditionDifferences = @(Get-AAConditionalAccessConditionsDifferences `
    -Expected $conditionsBody -Actual $verifiedConditions)
Assert-AAEqual 'Unchanged full conditions verification' $noConditionDifferences.Count 0
$verifiedConditions.applications.includeApplications = @()
$conditionDifferences = @(Get-AAConditionalAccessConditionsDifferences `
    -Expected $conditionsBody -Actual $verifiedConditions)
Assert-AATrue 'Dropped applications condition is detected' ($conditionDifferences -contains 'applications')
$verifiedConditions = $conditionsBody | ConvertTo-Json -Depth 50 | ConvertFrom-Json
$verifiedConditions.users.includeUsers = @()
$conditionDifferences = @(Get-AAConditionalAccessConditionsDifferences `
    -Expected $conditionsBody -Actual $verifiedConditions)
Assert-AATrue 'Dropped nested user condition is detected' ($conditionDifferences -contains 'users.includeUsers')

$directUser = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -IncludeUsers @($agentId)) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Direct user target action' $directUser.Action 'Exclude'

$groupTarget = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -IncludeUsers @() -IncludeGroups @($agentParentGroupId)) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId -AgentGroupIds $agentParentGroupId
Assert-AAEqual 'Transitive group target action' $groupTarget.Action 'Exclude'

$unrelatedApp = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -IncludeApplications @('55555555-5555-5555-5555-555555555555')) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId -ProtectedApplicationIds $graphSpId
Assert-AAEqual 'Unrelated application action' $unrelatedApp.Action 'NoAction'

$userAction = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -IncludeApplications @() -IncludeUserActions @('urn:user:registersecurityinfo') -BuiltInControls @('block')) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Security registration action' $userAction.Action 'NoAction'
Assert-AATrue 'Security registration classification' $userAction.IsUserActionPolicy

$disabled = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -State 'disabled') `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Disabled policy action' $disabled.Action 'NoAction'

$sessionOnly = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -BuiltInControls @()) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'No grant control action' $sessionOnly.Action 'NoAction'
Assert-AAEqual 'No grant control type' $sessionOnly.ControlType 'None'

$allExceptOffice = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -ExcludeApplications @('Office365')) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId -ProtectedApplicationIds $graphSpId
Assert-AAEqual 'All apps excluding Office 365 still targets Graph' $allExceptOffice.Action 'Exclude'

$allExceptGraph = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -ExcludeApplications @($graphSpId)) `
    -ExclusionGroupId $groupId -AgentUserIds $agentId -ProtectedApplicationIds $graphSpId
Assert-AAEqual 'All apps excluding Graph action' $allExceptGraph.Action 'NoAction'

$authStrength = Get-AAConditionalAccessPolicyAssessment `
    -Policy (New-AATestConditionalAccessPolicy -BuiltInControls @() -AuthenticationStrengthId '66666666-6666-6666-6666-666666666666') `
    -ExclusionGroupId $groupId -AgentUserIds $agentId
Assert-AAEqual 'Authentication strength control' $authStrength.ControlType 'Grant'
Assert-AAEqual 'Authentication strength action' $authStrength.Action 'Exclude'

Assert-AAEqual 'Missing secret without password' `
    (Get-AAAgentSecretWriteAction -SecretState Missing -HasAgentPassword $false) 'Missing'
Assert-AAEqual 'Missing secret with password' `
    (Get-AAAgentSecretWriteAction -SecretState Missing -HasAgentPassword $true -WriteMissingOnly) 'Write'
Assert-AAEqual 'Existing secret during partial repair' `
    (Get-AAAgentSecretWriteAction -SecretState Present -HasAgentPassword $true -WriteMissingOnly) 'Preserve'
Assert-AAEqual 'Existing secret during explicit synchronization' `
    (Get-AAAgentSecretWriteAction -SecretState Present -HasAgentPassword $true) 'Write'
Assert-AAEqual 'Existing secret without password' `
    (Get-AAAgentSecretWriteAction -SecretState Present -HasAgentPassword $false) 'Preserve'

$script:MockAzSecretState = 'Missing'
function global:az {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Alias('o')]$OutputFormat,
        [Parameter(ValueFromRemainingArguments = $true)]$Arguments
    )

    switch ($script:MockAzSecretState) {
        'Present' {
            $global:LASTEXITCODE = 0
            'https://example.vault.azure.net/secrets/persona/version'
        }
        'Missing' {
            $global:LASTEXITCODE = 1
            'ERROR: (SecretNotFound) A secret with (name/id) persona was not found in this key vault.'
        }
        'Denied' {
            $global:LASTEXITCODE = 1
            'ERROR: (Forbidden) The user does not have secrets get permission.'
        }
    }
}

try {
    $missingState = Get-AAKeyVaultSecretState -VaultName 'test-vault' -Name 'persona'
    Assert-AAEqual 'Key Vault missing state' $missingState.Status 'Missing'

    $script:MockAzSecretState = 'Present'
    $presentState = Get-AAKeyVaultSecretState -VaultName 'test-vault' -Name 'persona'
    Assert-AAEqual 'Key Vault present state' $presentState.Status 'Present'

    $script:MockAzSecretState = 'Denied'
    $accessErrorRaised = $false
    try {
        Get-AAKeyVaultSecretState -VaultName 'test-vault' -Name 'persona' | Out-Null
    } catch {
        $accessErrorRaised = $_.Exception.Message -match 'Failed to inspect Key Vault secret'
    }
    Assert-AATrue 'Key Vault access error is not treated as missing' $accessErrorRaised
} finally {
    Remove-Item Function:\global:az -ErrorAction SilentlyContinue
}

Write-Host '[PASS] Conditional Access and first-run secret guardrail tests passed.' -ForegroundColor Green
