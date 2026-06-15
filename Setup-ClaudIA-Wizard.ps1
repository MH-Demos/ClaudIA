<#PSScriptInfo

.VERSION 2.0.1
.GUID 6f1b2c4e-9a7d-4f3a-bd11-7c2e9f4a1d22

.AUTHOR
ClaudIA contributors

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA PowerShell Wizard Setup GUI Microsoft365 Azure

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Graphical, step-by-step setup wizard for ClaudIA aimed at non-technical users.

.RELEASENOTES
Version 2.0.1 (review of 2.0.0): fixed a systemic layout regression from the
2.0.0 anti-clipping polish (the page body label grew to 80px and overlapped the
first control of every page at y=110; now 66px) plus two specific overlaps (welcome list vs LAB checkbox; review summary vs the
dry-run checkbox after the time/cost line was added) and stopped merging stderr
into the prerequisite -AsJson stream, where a trailing warning could break JSON
parsing and cause a false deployment block.
Version 2.0.0 (post end-user dry-run): fixes the two BLOCK findings from the
field test - cross-tenant mismatch is now detected and the user is re-authed
into the correct tenant (and the tenant domain is auto-filled), and a NOT READY
prerequisite result now hard-blocks deployment instead of running anyway. Also:
the tool step checks required PowerShell modules, the provider list is derived
from the same config the prereq check reads (no more drift), browser agents are
OFF by default and trigger npm install when opted in, tool versions are shown,
the Step 1 "all installed" message is correct, step numbering is consistent
(4 steps), and a time/cost estimate is shown before Deploy.
Version 1.2.0 (fourth self-review iteration): removed DoEvents from Write-Log
(it could re-enter the deploy timer Tick from inside Tick and interleave tail
reads) in favor of a paint-only Update(), added an explicit pump in the
synchronous prerequisite phase, and a re-entrancy latch on the Tick handler.
Version 1.1.1 (third self-review iteration): stateful UTF-8 decoder for the
log tail (multibyte characters no longer garble at chunk boundaries, BOM is
stripped), and the completion message now reports the installer exit code and
detects an early crash that happened before the transcript existed.
Version 1.1.0 (second self-review iteration): the installer now runs in its own
visible console window while the wizard tails its transcript into the GUI -
this removes the silent-freeze risk if any module step prompts, and keeps the
UI thread free. Also: renamed an accidental assignment to the automatic
variable $args, added a FormClosing guard during deployment, deterministic
review-summary refresh, and -NonInteractive on the prerequisite child process.
Version 1.0.1 fixed the missing tenant.tenantId release blocker. 1.0.0 was the
first graphical wizard.

#>

<#
.SYNOPSIS
    ClaudIA graphical setup wizard.
.DESCRIPTION
    A friendly Windows wizard that walks a first-time user through deploying the
    ClaudIA lab without using the command line. It wraps the existing
    Install-ClaudIA.ps1 and prerequisites/Test-Prerequisites.ps1 scripts.

    The wizard never invents Microsoft requirements: it checks for PowerShell 7,
    Azure CLI, Git and Node.js, helps install the missing ones with winget,
    drives 'az login', registers the Azure resource providers Microsoft requires,
    and then launches the existing installer. All real deployment work is still
    performed by the audited PowerShell modules in this repository.
.NOTES
    Run via Start-ClaudIA.cmd (double-click) or:  pwsh -File Setup-ClaudIA-Wizard.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$InstallerPath = Join-Path $RepoRoot 'Install-ClaudIA.ps1'
$PrereqPath = Join-Path $RepoRoot 'prerequisites\Test-Prerequisites.ps1'
$ConfigPath = Join-Path $RepoRoot 'config\agents.json'

# When the operator runs multiple tenants from one repository they can create
# per-tenant config files in config\tenants\<key>.json (key = first DNS label of
# the tenant domain, e.g. contoso). If such a file exists for the tenant
# being deployed, the wizard reads/writes THAT file instead of the shared
# config\agents.json so the two tenants never clobber each other's resolved
# resource names. If no per-tenant file exists, behaviour is unchanged (shared
# file). This mirrors Resolve-AATenantConfigPath in modules\Common.ps1, kept
# inline here because the GUI wizard does not dot-source the module.
function Resolve-WizardTenantConfigPath {
    param([string]$Domain, [Parameter(Mandatory)][string]$Default)
    if (-not $Domain) { return $Default }
    $label = ($Domain -split '\.')[0]
    if (-not $label) { return $Default }
    $key = ($label -replace '[^A-Za-z0-9_-]', '')
    if (-not $key) { return $Default }
    $candidate = Join-Path $RepoRoot ('config\tenants\' + $key + '.json')
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $Default
}

# --- Guard: must run on PowerShell 7+ -------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'This wizard requires PowerShell 7. Please run Start-ClaudIA.cmd instead.' -ForegroundColor Red
    return
}

# --- Guard: must be a full repository -------------------------------------
if (-not (Test-Path -LiteralPath $InstallerPath) -or -not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host 'Install-ClaudIA.ps1 or config\agents.json was not found.' -ForegroundColor Red
    Write-Host 'Place this wizard in the ClaudIA repository root and try again.' -ForegroundColor Yellow
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ===========================================================================
# Helpers
# ===========================================================================
function Test-Tool { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-WithWinget {
    param([string]$Id)
    if (-not (Test-Tool 'winget')) { return $false }
    try {
        Start-Process -FilePath 'winget' -ArgumentList @(
            'install','--id',$Id,'--source','winget',
            '--accept-package-agreements','--accept-source-agreements'
        ) -Wait -NoNewWindow
        return $true
    } catch { return $false }
}

# Shared state collected across pages.
$script:State = [ordered]@{
    Domain         = ''
    TenantId       = ''
    SignedInUser   = ''
    SubscriptionId = ''
    ResourceGroup  = 'rg-claudia-lab'
    Location       = 'eastus'
    Country        = 'US'
    EnableBrowser  = $false
}

# Common Azure regions (short, friendly subset; users can still type their own).
$AzureRegions = @(
    'eastus','eastus2','westus','westus2','westus3','centralus',
    'northeurope','westeurope','francecentral','uksouth','germanywestcentral',
    'switzerlandnorth','swedencentral','australiaeast','canadacentral','japaneast'
)

# ===========================================================================
# Window + wizard frame
# ===========================================================================
$Font       = New-Object System.Drawing.Font('Segoe UI', 10)
$FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$FontStep   = New-Object System.Drawing.Font('Segoe UI', 9)
$ColorBg    = [System.Drawing.Color]::FromArgb(245,247,250)
$ColorAccent= [System.Drawing.Color]::FromArgb(0,90,158)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ClaudIA Setup Wizard'
$form.Size = New-Object System.Drawing.Size(720, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = $Font
$form.BackColor = $ColorBg
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# Header band
$header = New-Object System.Windows.Forms.Panel
$header.Size = New-Object System.Drawing.Size(720, 70)
$header.Location = New-Object System.Drawing.Point(0,0)
$header.BackColor = $ColorAccent
$form.Controls.Add($header)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.AutoSize = $false
$titleLabel.Size = New-Object System.Drawing.Size(700, 30)
$titleLabel.Location = New-Object System.Drawing.Point(20, 12)
$titleLabel.Font = $FontTitle
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Text = 'ClaudIA'
$header.Controls.Add($titleLabel)

$stepLabel = New-Object System.Windows.Forms.Label
$stepLabel.AutoSize = $false
$stepLabel.Size = New-Object System.Drawing.Size(680, 18)
$stepLabel.Location = New-Object System.Drawing.Point(22, 45)
$stepLabel.Font = $FontStep
$stepLabel.ForeColor = [System.Drawing.Color]::White
$header.Controls.Add($stepLabel)

# Content area (each page is a Panel swapped in/out)
$content = New-Object System.Windows.Forms.Panel
$content.Size = New-Object System.Drawing.Size(700, 460)
$content.Location = New-Object System.Drawing.Point(10, 80)
$form.Controls.Add($content)

# Footer buttons
$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = 'Back'
$btnBack.Size = New-Object System.Drawing.Size(100, 34)
$btnBack.Location = New-Object System.Drawing.Point(380, 558)
$form.Controls.Add($btnBack)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = 'Next'
$btnNext.Size = New-Object System.Drawing.Size(120, 34)
$btnNext.Location = New-Object System.Drawing.Point(490, 558)
$btnNext.BackColor = $ColorAccent
$btnNext.ForeColor = [System.Drawing.Color]::White
$btnNext.FlatStyle = 'Flat'
$form.Controls.Add($btnNext)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Size = New-Object System.Drawing.Size(100, 34)
$btnCancel.Location = New-Object System.Drawing.Point(20, 558)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

# ===========================================================================
# Page builders. Each returns a Panel and stores validation in .Tag (scriptblock).
# ===========================================================================
function New-Page {
    param([string]$Heading, [string]$Body)
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(700, 460)
    $p.Location = New-Object System.Drawing.Point(0,0)

    $h = New-Object System.Windows.Forms.Label
    $h.AutoSize = $false
    $h.Size = New-Object System.Drawing.Size(660, 32)
    $h.Location = New-Object System.Drawing.Point(20, 8)
    $h.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $h.ForeColor = $ColorAccent
    $h.Text = $Heading
    $p.Controls.Add($h)

    if ($Body) {
        $b = New-Object System.Windows.Forms.Label
        $b.AutoSize = $false
        $b.Size = New-Object System.Drawing.Size(660, 64)
        $b.Location = New-Object System.Drawing.Point(20, 44)
        $b.Text = $Body
        $p.Controls.Add($b)
    }
    return $p
}

function Add-Label {
    param($Panel, [string]$Text, [int]$X, [int]$Y, [int]$W = 300)
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size($W, 20)
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Text = $Text
    $Panel.Controls.Add($l)
    return $l
}

function Add-TextBox {
    param($Panel, [int]$X, [int]$Y, [int]$W = 380, [string]$Value = '')
    $t = New-Object System.Windows.Forms.TextBox
    $t.Size = New-Object System.Drawing.Size($W, 24)
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Text = $Value
    $Panel.Controls.Add($t)
    return $t
}

# ---- Page 1: Welcome ------------------------------------------------------
$page1 = New-Page -Heading 'Welcome' -Body @'
This wizard sets up a ClaudIA lab in your Microsoft 365 test tenant and Azure
subscription. It is for LAB AND DEMO USE ONLY. Do not use a production tenant.
'@
$lst = New-Object System.Windows.Forms.Label
$lst.AutoSize = $false
$lst.Size = New-Object System.Drawing.Size(660, 210)
$lst.Location = New-Object System.Drawing.Point(30, 112)
$lst.Text = @'
Before you start, make sure you have:

  -  A NON-production Microsoft 365 tenant (E5 or trial licenses recommended).
  -  An Azure subscription you can deploy resources into.
  -  An account that is Global Administrator in the tenant AND
     Owner/Contributor on the Azure subscription.
  -  About 30-60 minutes. Some Azure resources take time to create.

The wizard will install any missing tools for you and explain each step in
plain language. You can stop and re-run it at any time - it is safe to repeat.
'@
$page1.Controls.Add($lst)
$chkLab = New-Object System.Windows.Forms.CheckBox
$chkLab.AutoSize = $false
$chkLab.Size = New-Object System.Drawing.Size(660, 44)
$chkLab.Location = New-Object System.Drawing.Point(30, 332)
$chkLab.Text = 'I confirm this is a lab/demo environment and I have read the disclaimer.'
$page1.Controls.Add($chkLab)
$page1.Tag = {
    if (-not $chkLab.Checked) {
        [System.Windows.Forms.MessageBox]::Show('Please confirm this is a lab environment to continue.','ClaudIA') | Out-Null
        return $false
    }
    return $true
}

# ---- Page 2: Prerequisites tools -----------------------------------------
$page2 = New-Page -Heading 'Step 1 of 4 - Required tools' -Body @'
ClaudIA needs a few free Microsoft tools. The wizard can install the missing
ones for you using winget. Click "Check / Install" to begin.
'@
$toolGrid = New-Object System.Windows.Forms.Label
$toolGrid.AutoSize = $false
$toolGrid.Size = New-Object System.Drawing.Size(640, 178)
$toolGrid.Location = New-Object System.Drawing.Point(30, 110)
$toolGrid.Font = New-Object System.Drawing.Font('Consolas', 10)
$page2.Controls.Add($toolGrid)

$toolDefs = @(
    @{ Name='PowerShell 7'; Cmd='pwsh'; Id='Microsoft.PowerShell' },
    @{ Name='Azure CLI';    Cmd='az';   Id='Microsoft.AzureCLI' },
    @{ Name='Git';          Cmd='git';  Id='Git.Git' },
    @{ Name='Node.js LTS';  Cmd='node'; Id='OpenJS.NodeJS.LTS' }
)
# HIGH#3: the installer needs these PowerShell modules; the wizard now checks
# them up front instead of letting Step 4b fail after the user has clicked through.
$moduleDefs = @('Az.Accounts','ExchangeOnlineManagement','Microsoft.Graph.Authentication')

function Test-PsModule { param([string]$Name)
    [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
}
function Install-PsModuleForClaudIA {
    param([string]$Name)

    try {
        Install-Module -Name $Name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not install PowerShell module $Name.`n`n$($_.Exception.Message)`n`nYou can install it manually from PowerShell:`nInstall-Module $Name -Scope CurrentUser -Force", 'ClaudIA') | Out-Null
        return $false
    }
}
function Get-ToolVersion { param([string]$Cmd)
    try {
        switch ($Cmd) {
            'pwsh' { return $PSVersionTable.PSVersion.ToString() }
            'az'   { $v = (& az version --output json 2>$null | ConvertFrom-Json); return [string]$v.'azure-cli' }
            'node' { return ((& node --version 2>$null) -replace '^v','') }
            'git'  { return (((& git --version 2>$null) -split ' ')[-1]) }
        }
    } catch { }
    return ''
}
function Update-ToolGrid {
    $lines = foreach ($t in $toolDefs) {
        $ok = Test-Tool $t.Cmd
        $ver = if ($ok) { Get-ToolVersion $t.Cmd } else { '' }
        $state = if ($ok) { "[ installed ]  $ver" } else { '[ missing ]' }
        ('{0,-22} {1}' -f $t.Name, $state)
    }
    $lines += ''
    $lines += 'PowerShell modules:'
    foreach ($m in $moduleDefs) {
        $ok = Test-PsModule $m
        $lines += ('  {0,-34} {1}' -f $m, $(if ($ok) {'[ installed ]'} else {'[ missing ]'}))
    }
    $toolGrid.Text = ($lines -join "`r`n")
}
Update-ToolGrid

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Check / Install missing tools + modules'
$btnCheck.Size = New-Object System.Drawing.Size(320, 34)
$btnCheck.Location = New-Object System.Drawing.Point(30, 296)
$btnCheck.Add_Click({
    $missingTools = @($toolDefs | Where-Object { -not (Test-Tool $_.Cmd) })
    if ($missingTools.Count -gt 0 -and -not (Test-Tool 'winget')) {
        [System.Windows.Forms.MessageBox]::Show(
            "winget is not available. Install tools manually:`n" +
            "PowerShell 7: https://aka.ms/powershell-release?tag=stable`n" +
            "Azure CLI:    https://aka.ms/installazurecliwindows`n" +
            "Node.js LTS:  https://nodejs.org/", 'ClaudIA') | Out-Null
    } else {
        foreach ($t in $missingTools) {
                $btnCheck.Text = "Installing $($t.Name)..."
                $form.Refresh()
                Install-WithWinget -Id $t.Id | Out-Null
        }
    }
    foreach ($m in $moduleDefs) {
        if (-not (Test-PsModule $m)) {
            $btnCheck.Text = "Installing $m..."
            $form.Refresh()
            Install-PsModuleForClaudIA -Name $m | Out-Null
        }
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')
    Update-ToolGrid
    $btnCheck.Text = 'Check / Install missing tools + modules'
    [System.Windows.Forms.MessageBox]::Show(
        "Done. If any item still shows [ missing ], close the wizard and run Start-ClaudIA.cmd again so new tools and modules are detected.",
        'ClaudIA') | Out-Null
})
$page2.Controls.Add($btnCheck)
$page2.Tag = {
    # PowerShell 7 + Azure CLI are mandatory to continue.
    if (-not (Test-Tool 'pwsh') -or -not (Test-Tool 'az')) {
        [System.Windows.Forms.MessageBox]::Show('PowerShell 7 and Azure CLI are required before continuing.','ClaudIA') | Out-Null
        return $false
    }
    $missingModules = @($moduleDefs | Where-Object { -not (Test-PsModule $_) })
    if ($missingModules.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("Install the missing PowerShell module(s) before continuing:`n`n$($missingModules -join "`n")",'ClaudIA') | Out-Null
        return $false
    }
    return $true
}

# ---- Page 3: Azure sign-in -----------------------------------------------
$page3 = New-Page -Heading 'Step 2 of 4 - Sign in to Azure' -Body @'
Sign in with the account that owns the lab subscription. A browser window will
open. After sign-in, pick the subscription ClaudIA should deploy into.
'@
$btnLogin = New-Object System.Windows.Forms.Button
$btnLogin.Text = 'Sign in to Azure'
$btnLogin.Size = New-Object System.Drawing.Size(180, 34)
$btnLogin.Location = New-Object System.Drawing.Point(30, 110)
$page3.Controls.Add($btnLogin)

Add-Label -Panel $page3 -Text 'Subscription:' -X 30 -Y 165 -W 100 | Out-Null
$cmbSub = New-Object System.Windows.Forms.ComboBox
$cmbSub.Size = New-Object System.Drawing.Size(540, 24)
$cmbSub.Location = New-Object System.Drawing.Point(30, 188)
$cmbSub.DropDownStyle = 'DropDownList'
$page3.Controls.Add($cmbSub)

$lblSignedIn = Add-Label -Panel $page3 -Text '' -X 220 -Y 118 -W 360
$lblSignedIn.ForeColor = [System.Drawing.Color]::DarkGreen

$script:SubMap = @{}
$btnLogin.Add_Click({
    $btnLogin.Text = 'Opening browser...'; $form.Refresh()
    try {
        & az login --only-show-errors *> $null
        $acct = & az account show -o json 2>$null | ConvertFrom-Json
        if ($acct) {
            $lblSignedIn.Text = "Signed in as $($acct.user.name)"
            $script:State.SignedInUser = [string]$acct.user.name
            $script:State.Domain = $acct.tenantDefaultDomain
            $script:State.TenantId = [string]$acct.tenantId
        }
        $subs = & az account list --all -o json 2>$null | ConvertFrom-Json
        $cmbSub.Items.Clear(); $script:SubMap = @{}
        $subs = @($subs | Sort-Object @{ Expression = {
            if ($_.tenantId -eq $script:State.TenantId) { 0 } else { 1 }
        }}, @{ Expression = { $_.name }})
        foreach ($s in $subs) {
            # Show the tenant for EVERY subscription so a cross-tenant pick is visible.
            $marker = if ($s.tenantId -eq $script:State.TenantId) { '' } else { '  <- DIFFERENT TENANT' }
            $label = "$($s.name)  ($($s.id))  [tenant $($s.tenantId)]$marker"
            [void]$cmbSub.Items.Add($label)
            $script:SubMap[$label] = $s
        }
        if ($cmbSub.Items.Count -gt 0) {
            $cmbSub.SelectedIndex = 0
            if ($subs[0].tenantId -ne $script:State.TenantId) {
                $lblSignedIn.Text += '  [WARNING: no subscription found in this tenant]'
            }
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Sign-in failed: $($_.Exception.Message)",'ClaudIA') | Out-Null
    }
    $btnLogin.Text = 'Sign in to Azure'
})
$page3.Tag = {
    if (-not ($cmbSub.SelectedItem -and $script:SubMap.ContainsKey([string]$cmbSub.SelectedItem))) {
        [System.Windows.Forms.MessageBox]::Show('Sign in and select a subscription to continue.','ClaudIA') | Out-Null
        return $false
    }
    $sel = $script:SubMap[[string]$cmbSub.SelectedItem]
    $selTenant = [string]$sel.tenantId

    # BLOCK#1: if the chosen subscription lives in a different tenant than the
    # one we authenticated against, the cached token is wrong. Re-auth INTO that
    # tenant explicitly rather than silently deploying cross-tenant.
    if ($selTenant -and $script:State.TenantId -and $selTenant -ne $script:State.TenantId) {
        $msg = "The subscription you picked belongs to tenant`n  $selTenant`nbut you signed in to tenant`n  $($script:State.TenantId).`n`nSign in again to the subscription's tenant now?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg,'ClaudIA - tenant mismatch',[System.Windows.Forms.MessageBoxButtons]::OKCancel)
        if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
        try {
            & az login --tenant $selTenant --only-show-errors *> $null
            if ($LASTEXITCODE -ne 0) { throw "az login exited with code $LASTEXITCODE" }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not sign in to tenant $selTenant.`n`n$($_.Exception.Message)`n`nSelect a subscription in the tenant you are signed in to, or try signing in again.",'ClaudIA - tenant sign-in failed') | Out-Null
            return $false
        }
    }

    $script:State.SubscriptionId = $sel.id
    $script:State.TenantId = $selTenant
    & az account set --subscription $sel.id 2>$null

    # Re-read the active context so domain + UPN reflect the FINAL selection.
    $acct = & az account show -o json 2>$null | ConvertFrom-Json
    if ($acct) {
        $script:State.SignedInUser = [string]$acct.user.name
        $script:State.TenantId = [string]$acct.tenantId
    }
    if ($selTenant -and $script:State.TenantId -and $script:State.TenantId -ne $selTenant) {
        [System.Windows.Forms.MessageBox]::Show("Azure CLI is still signed in to tenant $($script:State.TenantId), but the selected subscription belongs to $selTenant.`n`nSign in to the selected tenant before continuing.",'ClaudIA - tenant mismatch') | Out-Null
        return $false
    }

    # Resolve the primary verified domain from Graph (authoritative), falling
    # back to the signed-in UPN suffix. This auto-fills Step 3 (MED).
    $resolvedDomain = ''
    try {
        $org = & az rest --method get --url 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains' -o json 2>$null | ConvertFrom-Json
        if ($org -and $org.value) {
            $primary = $org.value[0].verifiedDomains | Where-Object { $_.isDefault } | Select-Object -First 1
            if ($primary) { $resolvedDomain = [string]$primary.name }
        }
    } catch {}
    if (-not $resolvedDomain -and $script:State.SignedInUser -match '@') {
        $resolvedDomain = ($script:State.SignedInUser -split '@')[-1]
    }
    if ($resolvedDomain) { $script:State.Domain = $resolvedDomain }
    return $true
}

# ---- Page 4: Lab settings -------------------------------------------------
$page4 = New-Page -Heading 'Step 3 of 4 - Lab settings' -Body @'
These are the only values ClaudIA needs from you. Defaults are fine for most
labs. The resource group is just a NAME (not the subscription number).
'@
Add-Label -Panel $page4 -Text 'Tenant domain (e.g. contoso.onmicrosoft.com):' -X 30 -Y 110 -W 420 | Out-Null
$txtDomain = Add-TextBox -Panel $page4 -X 30 -Y 132 -W 540 -Value $script:State.Domain

Add-Label -Panel $page4 -Text 'Resource group name:' -X 30 -Y 168 -W 250 | Out-Null
$txtRg = Add-TextBox -Panel $page4 -X 30 -Y 190 -W 260 -Value $script:State.ResourceGroup

Add-Label -Panel $page4 -Text 'Azure region:' -X 310 -Y 168 -W 250 | Out-Null
$cmbLoc = New-Object System.Windows.Forms.ComboBox
$cmbLoc.Size = New-Object System.Drawing.Size(260, 24)
$cmbLoc.Location = New-Object System.Drawing.Point(310, 190)
$cmbLoc.DropDownStyle = 'DropDown'
$AzureRegions | ForEach-Object { [void]$cmbLoc.Items.Add($_) }
$cmbLoc.Text = $script:State.Location
$page4.Controls.Add($cmbLoc)

Add-Label -Panel $page4 -Text 'User country code (2 letters, e.g. US, FR, GB):' -X 30 -Y 226 -W 420 | Out-Null
$txtCountry = Add-TextBox -Panel $page4 -X 30 -Y 248 -W 80 -Value $script:State.Country

$chkBrowser = New-Object System.Windows.Forms.CheckBox
$chkBrowser.AutoSize = $false
$chkBrowser.Size = New-Object System.Drawing.Size(620, 40)
$chkBrowser.Location = New-Object System.Drawing.Point(30, 290)
$chkBrowser.Text = 'Also set up browser-agent automation (optional). Adds Playwright + extra Azure resources (Container Registry, Container Apps, Load Test) and ongoing cost. Leave OFF unless you need it.'
$chkBrowser.Checked = $false
$page4.Controls.Add($chkBrowser)

$page4.Tag = {
    $d = $txtDomain.Text.Trim()
    $rg = $txtRg.Text.Trim()
    $c = $txtCountry.Text.Trim()
    if ($d -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
        [System.Windows.Forms.MessageBox]::Show('Enter a valid tenant domain, e.g. contoso.onmicrosoft.com.','ClaudIA') | Out-Null; return $false
    }
    $parsedGuid = [guid]::Empty
    if ($rg -eq $script:State.SubscriptionId -or [guid]::TryParse($rg, [ref]$parsedGuid)) {
        [System.Windows.Forms.MessageBox]::Show('Resource group must be a NAME like rg-claudia-lab, not the subscription id.','ClaudIA') | Out-Null; return $false
    }
    if ($rg -notmatch '^[A-Za-z0-9_.\-()]{1,90}$') {
        [System.Windows.Forms.MessageBox]::Show('Resource group name has invalid characters.','ClaudIA') | Out-Null; return $false
    }
    $locValue = $cmbLoc.Text.Trim().ToLowerInvariant()
    if ($locValue -notmatch '^[a-z0-9]{3,30}$') {
        [System.Windows.Forms.MessageBox]::Show('Pick or type a valid Azure region, e.g. eastus or westeurope.','ClaudIA') | Out-Null; return $false
    }
    if ($c -notmatch '^[A-Za-z]{2}$') {
        [System.Windows.Forms.MessageBox]::Show('Country code must be exactly 2 letters, e.g. US.','ClaudIA') | Out-Null; return $false
    }
    # BLOCK#1 secondary: the typed domain must match the tenant we authenticated
    # to, otherwise the deployment targets a different directory than the user
    # believes. Compare against the signed-in UPN suffix.
    if ($script:State.SignedInUser -match '@') {
        $upnSuffix = ($script:State.SignedInUser -split '@')[-1]
        if ($upnSuffix -and ($d -notlike "*$upnSuffix*") -and ($upnSuffix -notlike "*$d*")) {
            $msg = "The domain you entered ($d) does not match your signed-in account ($($script:State.SignedInUser)).`n`nDeploying would target a different tenant than the one you are signed in to. Use $upnSuffix instead?"
            $ans = [System.Windows.Forms.MessageBox]::Show($msg,'ClaudIA - domain mismatch',[System.Windows.Forms.MessageBoxButtons]::YesNoCancel)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { $d = $upnSuffix; $txtDomain.Text = $d }
            elseif ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
            # No = keep what they typed (they may know better), fall through.
        }
    }
    $script:State.Domain = $d
    $script:State.ResourceGroup = $rg
    $script:State.Location = $locValue
    $script:State.Country = $c.ToUpperInvariant()
    $script:State.EnableBrowser = $chkBrowser.Checked
    return $true
}

# ---- Page 5: Review + deploy ---------------------------------------------
$page5 = New-Page -Heading 'Step 4 of 4 - Review and deploy' -Body @'
Check the summary below. When you click Deploy, the wizard writes your settings
into config\agents.json, checks prerequisites, and runs the installer. In full
deployment mode it can also register Azure providers. A live log appears below.
'@
$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.AutoSize = $false
$lblSummary.Size = New-Object System.Drawing.Size(650, 224)
$lblSummary.Location = New-Object System.Drawing.Point(30, 110)
$lblSummary.Font = New-Object System.Drawing.Font('Consolas', 10)
$page5.Controls.Add($lblSummary)

$chkDry = New-Object System.Windows.Forms.CheckBox
$chkDry.AutoSize = $false
$chkDry.Size = New-Object System.Drawing.Size(650, 40)
$chkDry.Location = New-Object System.Drawing.Point(30, 344)
$chkDry.Text = 'Do a dry run first (saves local config files, creates no Azure/M365 resources).'
$chkDry.Checked = $true
$page5.Controls.Add($chkDry)

# Deployment scope picker: full run (default) or a single step. The installer
# accepts -Step N (runs ONLY that step), which is how you resume after fixing a
# blocker - e.g. re-login then run only Step 5. $null = full deployment.
$script:StepChoices = @(
    @{ Label = 'Full deployment (all steps, recommended)'; Step = $null }
    @{ Label = 'Step 1  - Create agent users';             Step = 1 }
    @{ Label = 'Step 2  - Licenses + MFA exclusion group';  Step = 2 }
    @{ Label = 'Step 3  - Register Entra app';              Step = 3 }
    @{ Label = 'Step 4  - Azure infra (+4a/4b labels/4c Fabric)'; Step = 4 }
    @{ Label = 'Step 5  - Store secrets + deploy runbook';  Step = 5 }
    @{ Label = 'Step 6  - Purview DLP + IRM';               Step = 6 }
    @{ Label = 'Step 7  - Activity Monitor workbook';       Step = 7 }
    @{ Label = 'Step 8  - Activity Story Map';              Step = 8 }
    @{ Label = 'Step 9  - Browser-agent cloud automation';  Step = 9 }
    @{ Label = 'Step 10 - MDCA Cloud Discovery connector';  Step = 10 }
)

$lblScope = New-Object System.Windows.Forms.Label
$lblScope.AutoSize = $true
$lblScope.Location = New-Object System.Drawing.Point(30, 392)
$lblScope.Text = 'Scope:'
$page5.Controls.Add($lblScope)

$cmbStep = New-Object System.Windows.Forms.ComboBox
$cmbStep.DropDownStyle = 'DropDownList'
$cmbStep.Size = New-Object System.Drawing.Size(560, 24)
$cmbStep.Location = New-Object System.Drawing.Point(90, 388)
foreach ($sc in $script:StepChoices) { [void]$cmbStep.Items.Add($sc.Label) }
$cmbStep.SelectedIndex = 0
$page5.Controls.Add($cmbStep)
$cmbStep.Add_SelectedIndexChanged({ Update-Page5Summary })

function Update-Page5Summary {
    $runMode = if ($chkDry.Checked) { 'Dry run: plan only, no cloud resources' } else { 'Full deployment: creates/updates lab resources' }
    $scopeText = if ($cmbStep -and $cmbStep.SelectedIndex -gt 0) { $script:StepChoices[$cmbStep.SelectedIndex].Label } else { 'All steps' }
    $lblSummary.Text = @"
Estimated time : 30-60 min   |   Idle Azure cost: a few USD/day (lab resources)
Run mode       : $runMode
Scope          : $scopeText

Tenant domain   : $($script:State.Domain)
Tenant id       : $($script:State.TenantId)
Subscription    : $($script:State.SubscriptionId)
Resource group  : $($script:State.ResourceGroup)
Azure region    : $($script:State.Location)
Country code    : $($script:State.Country)
Browser agents  : $(if ($script:State.EnableBrowser) {'Yes'} else {'No'})
"@
}
$page5.Tag = {
    if (-not $script:State.TenantId) {
        [System.Windows.Forms.MessageBox]::Show('Tenant id was not captured. Go back to the Azure sign-in step and sign in again.','ClaudIA') | Out-Null
        return $false
    }
    return $true
}

# ---- Page 6: Run + log ----------------------------------------------------
$page6 = New-Page -Heading 'Running deployment' -Body ''
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Size = New-Object System.Drawing.Size(660, 400)
$logBox.Location = New-Object System.Drawing.Point(20, 50)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.ForeColor = [System.Drawing.Color]::Gainsboro
$page6.Controls.Add($logBox)
$page6.Tag = { return $true }

function Write-Log { param([string]$Text)
    $logBox.AppendText($Text + "`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
    # Paint without pumping the message queue: DoEvents here could re-enter the
    # deploy timer's Tick from inside Tick (interleaved tail reads). Update()
    # only repaints this control and cannot dispatch other events.
    $logBox.Update()
}

function Update-AgentsConfig {
    # Write the few collected values into the active config file, preserving the
    # rest. If a per-tenant file exists for the deploying domain, retarget to it
    # so multi-tenant runs stay isolated (see Resolve-WizardTenantConfigPath).
    $script:ConfigPath = Resolve-WizardTenantConfigPath -Domain $script:State.Domain -Default $script:ConfigPath
    try {
        $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if (-not $json -or -not $json.tenant) { throw 'missing the [tenant] section' }
    } catch {
        throw "Config file '$ConfigPath' is missing or not valid JSON ($($_.Exception.Message)). Restore it from source control (or delete the per-tenant copy under config\tenants\) and try again."
    }
    $json.tenant.domain = $script:State.Domain
    $json.tenant.tenantId = $script:State.TenantId
    $json.tenant.subscriptionId = $script:State.SubscriptionId
    $json.tenant.location = $script:State.Location
    $json.tenant.country = $script:State.Country
    if (-not $json.infrastructure) { $json | Add-Member -NotePropertyName infrastructure -NotePropertyValue ([pscustomobject]@{}) }
    $json.infrastructure.resourceGroup = $script:State.ResourceGroup
    if ($json.browserAgents) { $json.browserAgents.enabled = [bool]$script:State.EnableBrowser }
    if ($json.adx -and $json.adx.PSObject.Properties['tenantId']) { $json.adx.tenantId = $script:State.TenantId }
    # Depth 20 so deeply nested sections are never silently truncated.
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
}

function Start-Deployment {
    $btnNext.Enabled = $false; $btnBack.Enabled = $false
    try {
        Write-Log '=== Writing configuration ==='
        Update-AgentsConfig
        Write-Log "Saved settings to config\agents.json"

        # Resolve the deployment scope once: $null = full run, otherwise a single
        # step to run in isolation (resume). Reused by the prereq gate and the
        # installer args below so they can never disagree.
        $selStep = $null
        if ($cmbStep -and $cmbStep.SelectedIndex -gt 0) { $selStep = $script:StepChoices[$cmbStep.SelectedIndex].Step }
        $singleStep = ($null -ne $selStep)

                Write-Log ''
                # HIGH#4: derive the provider list from the SAME config the prereq check
                # reads, so the two can never drift. Mirrors Get-RequiredProviders.
        $providers = [System.Collections.Generic.List[string]]::new()
        @('Microsoft.KeyVault','Microsoft.CognitiveServices','Microsoft.Automation',
          'Microsoft.Insights','Microsoft.Storage','Microsoft.Web') | ForEach-Object { $providers.Add($_) }
        try {
            $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($cfg.adx -and $cfg.adx.enabled) { $providers.Add('Microsoft.Kusto') }
            if ($cfg.infrastructure -and $cfg.infrastructure.fabricEnabled) { $providers.Add('Microsoft.Fabric') }
            if ($cfg.activityStoryMap -and $cfg.activityStoryMap.frontDoor -and $cfg.activityStoryMap.frontDoor.enabled) { $providers.Add('Microsoft.Cdn') }
            if ($cfg.browserAgents -and $cfg.browserAgents.enabled) {
                @('Microsoft.LoadTestService','Microsoft.App','Microsoft.ContainerRegistry','Microsoft.ManagedIdentity') | ForEach-Object { $providers.Add($_) }
            }
            if (($cfg.PSObject.Properties.Name -contains 'graphMeteredBilling') -and $cfg.graphMeteredBilling.enabled) { $providers.Add('Microsoft.GraphServices') }
        } catch {}
        if ($chkDry.Checked) {
            Write-Log '=== Dry run: Azure provider registration skipped ==='
            Write-Log "Would register/check: $((($providers | Select-Object -Unique) -join ', '))"
        } else {
            Write-Log '=== Registering Azure resource providers (required by Microsoft) ==='
            foreach ($pr in ($providers | Select-Object -Unique)) {
                Write-Log "  registering $pr ..."
                & az provider register -n $pr 2>$null | Out-Null
                [System.Windows.Forms.Application]::DoEvents()
            }
        }

        # LOW: install npm deps if the user opted into browser agents.
        if ($script:State.EnableBrowser) {
            $baDir = Join-Path $RepoRoot 'BrowserAgents'
            if (Test-Path -LiteralPath (Join-Path $baDir 'package.json')) {
                Write-Log ''
                Write-Log '=== Installing browser-agent dependencies (npm install) ==='
                & cmd /c "cd /d `"$baDir`" && npm install" 2>&1 | ForEach-Object {
                    Write-Log ([string]$_); [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }

        Write-Log ''
        Write-Log '=== Running prerequisite checks ==='
        Write-Log 'Please wait - this can take 10-30 seconds (module + Azure checks). The window may look frozen.'
        [System.Windows.Forms.Application]::DoEvents()
        # BLOCK#2: capture the structured result and GATE on it. A NOT READY must
        # stop the wizard, not scroll past while the installer runs anyway.
        # stdout only: with -AsJson the script's stdout is pure JSON; merging
        # stderr (2>&1) could append warnings after the JSON and break parsing.
        # -ConfigPath: use the SAME file Update-AgentsConfig wrote (per-tenant
        # file when one exists); without it the child defaults to the shared
        # config\agents.json template, which is intentionally blank.
        $prereqRaw = & pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PrereqPath -ConfigPath $ConfigPath -AsJson 2>$null
        $prereqText = ($prereqRaw | Out-String)
        $prereq = $null
        try {
            $jsonStart = $prereqText.IndexOf('{')
            if ($jsonStart -ge 0) { $prereq = $prereqText.Substring($jsonStart) | ConvertFrom-Json }
        } catch {}

        if ($prereq) {
            foreach ($r in $prereq.Results) {
                if ($r.Status -eq 'Fail') {
                    Write-Log ("[FAIL] {0} - Fix: {1}" -f $r.Name, $r.Fix)
                    if ($r.Detail) { Write-Log ("        Detail: {0}" -f $r.Detail) }
                }
            }
            if (-not $prereq.AllPassed) {
                Write-Log ''
                if ($singleStep) {
                    # Single-step resume: the user is intentionally re-running one
                    # step (often after fixing a transient). Do not hard-block on
                    # prereqs that may be unrelated to this step - warn and let them
                    # decide. Full deployments still hard-block below.
                    Write-Log "=== $($prereq.FailedCount) prerequisite check(s) failed (single-step mode: Step $selStep). ==="
                    $ans = [System.Windows.Forms.MessageBox]::Show(
                        "$($prereq.FailedCount) prerequisite check(s) failed. You chose to run ONLY Step $selStep.`n`nSome failures may not apply to this step. Continue with Step $selStep anyway?",
                        'ClaudIA - prerequisites not fully met', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) {
                        Write-Log 'Deployment cancelled by user. Fix the checks above, then Deploy again.'
                        $btnBack.Enabled = $true; $btnNext.Text = 'Finish'; $btnNext.Enabled = $true
                        return
                    }
                    Write-Log "Proceeding with Step $selStep despite prerequisite warnings (user confirmed)."
                } else {
                    Write-Log "=== NOT READY: $($prereq.FailedCount) check(s) failed. Deployment is BLOCKED. ==="
                    Write-Log 'Fix the failed checks above (their Fix: commands), then click Back and Deploy again.'
                    Write-Log 'Tip: most are "Install-Module ..." or "az provider register ...".'
                    [System.Windows.Forms.MessageBox]::Show(
                        "Prerequisites are NOT READY ($($prereq.FailedCount) failed). The deployment was blocked to protect you. See the failed checks and their Fix commands in the log, resolve them, then try Deploy again.",
                        'ClaudIA - blocked', [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                    $btnBack.Enabled = $true
                    $btnNext.Text = 'Finish'
                    $btnNext.Enabled = $true
                    return
                }
            } else {
                Write-Log "All $($prereq.PassedCount) prerequisite checks passed."
            }
        } else {
            # Could not parse the result: fail safe (block), do not run blindly.
            Write-Log $prereqText
            Write-Log ''
            Write-Log '=== Could not confirm prerequisites passed. Deployment is BLOCKED as a precaution. ==='
            [System.Windows.Forms.MessageBox]::Show('Could not read the prerequisite check result. Deployment was blocked. Run prerequisites/Test-Prerequisites.ps1 manually to investigate.','ClaudIA - blocked') | Out-Null
            $btnBack.Enabled = $true; $btnNext.Text = 'Finish'; $btnNext.Enabled = $true
            return
        }

        Write-Log ''
        $mode = if ($chkDry.Checked) { 'DRY RUN' } else { 'FULL DEPLOYMENT' }
        Write-Log "=== Running installer ($mode) ==="
        # L1-5: run the installer in its OWN visible console window instead of
        # piping it into the GUI thread. Reasons:
        #   - Some module steps can legitimately prompt (e.g. a Connect-IPPSSession
        #     fallback). Piped + hidden, such a prompt would freeze the wizard
        #     forever with no visible cause. In a real console the user can answer.
        #   - The GUI thread is never blocked, so the window stays responsive
        #     without relying on DoEvents for the long run.
        # The wizard then TAILS the installer's own transcript (logs\Install-ClaudIA-*.log)
        # into this log box via a timer, so progress is still mirrored here.
        $installerArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$InstallerPath`"",'-ConfigPath',"`"$ConfigPath`"",'-Auto','-SkipPrerequisites')
        if ($chkDry.Checked) { $installerArgs += '-DryRun' }
        # Single-step scope: pass -Step N so the installer runs ONLY that step
        # (used to resume after fixing a blocker). $selStep was resolved above.
        if ($singleStep) {
            $installerArgs += @('-Step', "$selStep")
            Write-Log "Scope: running ONLY Step $selStep (single-step mode)."
        }

        Write-Log 'A separate console window is opening for the installer.'
        Write-Log 'If that window asks a question, answer it THERE. Progress is mirrored below.'
        Write-Log ''

        $script:DeployStart = Get-Date
        $script:DeployProc = Start-Process -FilePath 'pwsh' -ArgumentList $installerArgs `
            -WorkingDirectory $RepoRoot -PassThru
        $script:TailPath = $null
        $script:TailOffset = 0
        # Stateful decoder: a UTF-8 character split across two reads would
        # otherwise decode as garbage at every chunk boundary.
        $script:TailDecoder = [System.Text.UTF8Encoding]::new($false).GetDecoder()
        $script:DeployIsDryRun = [bool]$chkDry.Checked
        $deployTimer.Start()
    } catch {
        Write-Log ''
        Write-Log "[ERROR] $($_.Exception.Message)"
        $btnBack.Enabled = $true
        $btnNext.Text = 'Finish'
        $btnNext.Enabled = $true
    }
}

function Read-NewLogText {
    # Find the newest transcript created after launch, then stream appended bytes.
    if (-not $script:TailPath) {
        $logDir = Join-Path $RepoRoot 'logs'
        if (Test-Path -LiteralPath $logDir) {
            $candidate = Get-ChildItem -LiteralPath $logDir -Filter 'Install-ClaudIA-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -ge $script:DeployStart.AddSeconds(-5) } |
                Sort-Object CreationTime -Descending | Select-Object -First 1
            if ($candidate) { $script:TailPath = $candidate.FullName }
        }
        if (-not $script:TailPath) { return $null }
        Write-Log "Following installer log: $script:TailPath"
    }
    try {
        $fs = [System.IO.File]::Open($script:TailPath, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $script:TailOffset) { return $null }
            $fs.Seek($script:TailOffset, 'Begin') | Out-Null
            $buf = [byte[]]::new($fs.Length - $script:TailOffset)
            $read = $fs.Read($buf, 0, $buf.Length)
            $script:TailOffset += $read
            $chars = [char[]]::new($script:TailDecoder.GetCharCount($buf, 0, $read))
            $count = $script:TailDecoder.GetChars($buf, 0, $read, $chars, 0)
            $text = [string]::new($chars, 0, $count)
            return $text.TrimStart([char]0xFEFF)
        } finally { $fs.Dispose() }
    } catch { return $null }
}

$deployTimer = New-Object System.Windows.Forms.Timer
$deployTimer.Interval = 700
$deployTimer.Add_Tick({
    if ($script:TickBusy) { return }
    $script:TickBusy = $true
    try {
    $chunk = Read-NewLogText
    if ($chunk) {
        foreach ($line in ($chunk -split "`r?`n")) {
            if ($line.Trim()) { Write-Log $line }
        }
    }
    # If the installer is still running but no transcript has appeared after a
    # while, tell the user once (the console window may be waiting on a prompt or
    # the installer may have crashed before it could create its log file).
    if ($script:DeployProc -and -not $script:DeployProc.HasExited -and -not $script:TailPath) {
        if (((Get-Date) - $script:DeployStart).TotalSeconds -gt 20 -and -not $script:TailWarned) {
            $script:TailWarned = $true
            Write-Log '[WAIT] Installer is running but has not created a log file yet.'
            Write-Log '       Check the separate console window - it may be asking a question or showing an early error.'
        }
    }
    if ($script:DeployProc -and $script:DeployProc.HasExited) {
        Start-Sleep -Milliseconds 300
        $final = Read-NewLogText
        if ($final) {
            foreach ($line in ($final -split "`r?`n")) {
                if ($line.Trim()) { Write-Log $line }
            }
        }
        $deployTimer.Stop()
        $exitCode = $script:DeployProc.ExitCode
        Write-Log ''
        if (-not $script:TailPath) {
            Write-Log "[FAILED] The installer exited (code $exitCode) before writing any log file."
            Write-Log '       It probably stopped during its startup checks. Read the message in'
            Write-Log '       the console window, or re-run from PowerShell to see the error:'
            Write-Log '       .\Install-ClaudIA.ps1'
            [System.Windows.Forms.MessageBox]::Show(
                "The installer stopped early (exit code $exitCode) before writing a log file. Check the separate console window for the error, then try Deploy again.",
                'ClaudIA - deployment failed', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } elseif ($exitCode -ne 0) {
            Write-Log "[FAILED] Deployment exited with code $exitCode. Review the errors above and the logs folder."
            [System.Windows.Forms.MessageBox]::Show(
                "Deployment FAILED (exit code $exitCode). Scroll up in the log to the first [FAIL]/ERROR line for the cause, fix it, then use the Scope picker to re-run just the failed step.",
                'ClaudIA - deployment failed', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } elseif ($script:DeployIsDryRun) {
            Write-Log '=== Dry run finished (exit code 0). No Azure/M365 resources were created. ==='
            Write-Log '    Click Back, untick "dry run", and Deploy again to run for real.'
            [System.Windows.Forms.MessageBox]::Show(
                "Dry run completed successfully (exit code 0). No Azure or M365 resources were created - only local config was written.`n`nClick Back, untick 'Do a dry run first', and Deploy again to run for real.",
                'ClaudIA - dry run complete', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            Write-Log '=== Deployment finished (exit code 0). Review the log above for any warnings. ==='
            [System.Windows.Forms.MessageBox]::Show(
                'Deployment finished (exit code 0). Review the log for any warnings (e.g. optional Fabric).',
                'ClaudIA - deployment complete', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        $script:DeployProc = $null
        $btnBack.Enabled = $true
        $btnNext.Text = 'Finish'
        $btnNext.Enabled = $true
    }
    } finally { $script:TickBusy = $false }
})

# ===========================================================================
# Navigation engine
# ===========================================================================
$pages = @($page1, $page2, $page3, $page4, $page5, $page6)
$titles = @(
    'Welcome to the ClaudIA setup wizard',
    'Step 1 of 4 - Install the tools and modules ClaudIA needs',
    'Step 2 of 4 - Connect ClaudIA to your Azure subscription',
    'Step 3 of 4 - Tell ClaudIA about your lab',
    'Step 4 of 4 - Confirm your choices before deploying',
    'Running deployment - prerequisites are checked first'
)
$script:Index = 0

function Show-Page {
    param([int]$i)
    $content.Controls.Clear()
    $content.Controls.Add($pages[$i])
    $pages[$i].Visible = $true
    $stepLabel.Text = $titles[$i]
    if ($i -eq 3 -and $script:State.Domain) { $txtDomain.Text = $script:State.Domain }
    if ($i -eq 4) { Update-Page5Summary }
    $btnBack.Enabled = ($i -gt 0 -and $i -lt ($pages.Count - 1))
    if ($i -eq ($pages.Count - 2)) { $btnNext.Text = 'Deploy' }
    elseif ($i -eq ($pages.Count - 1)) { $btnNext.Text = 'Finish' }
    else { $btnNext.Text = 'Next' }
}

$btnBack.Add_Click({
    if ($script:Index -gt 0) { $script:Index--; Show-Page $script:Index }
})

$btnNext.Add_Click({
    $current = $pages[$script:Index]
    $validator = $current.Tag
    if ($validator -and -not (& $validator)) { return }

    if ($script:Index -eq ($pages.Count - 1)) { $form.Close(); return }

    $script:Index++
    Show-Page $script:Index

    # Entering the final page kicks off the deployment automatically.
    if ($script:Index -eq ($pages.Count - 1)) {
        $btnNext.Enabled = $false
        $form.Refresh()
        Start-Deployment
    }
})

$form.Add_FormClosing({
    param($formSender, $closeArgs)
    if ($script:DeployProc -and -not $script:DeployProc.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "A deployment is still running in the separate console window.`n`nClosing the wizard will NOT stop it - the console keeps running and writes its log to the logs folder.`n`nClose the wizard anyway?",
            'ClaudIA', [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $closeArgs.Cancel = $true }
    }
})

Show-Page 0
[void]$form.ShowDialog()
