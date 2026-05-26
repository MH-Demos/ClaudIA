<#PSScriptInfo

.VERSION 1.0.0

.GUID 2f78e96e-b5ab-4dc6-aa35-cce19071a321

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA Update Scripts PowerShell

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Updates ClaudIA PowerShell scripts from the published GitHub manifest

.RELEASENOTES
Initial version metadata for Updates ClaudIA PowerShell scripts from the published GitHub manifest.

#>

<#
.SYNOPSIS
    Updates ClaudIA PowerShell scripts from the published GitHub manifest.
.DESCRIPTION
    Reads UpdateInfo/update.json from the ClaudIA repository, compares the local
    PSScriptInfo version of each listed PowerShell script, backs up changed local
    files, and downloads newer script versions. Configuration and generated lab
    files are intentionally not included in the script update manifest.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepositoryRawUri = 'https://raw.githubusercontent.com/MH-Demos/ClaudIA/main',
    [string]$ManifestPath = 'UpdateInfo/update.json',
    [string]$BackupFolderName = 'BackupScripts',
    [switch]$IncludeSupportFiles,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..')
    return $root.Path
}

function Get-LocalScriptVersion {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $info = Test-ScriptFileInfo -Path $Path -ErrorAction Stop
        return [version]$info.Version
    } catch {
        return $null
    }
}

function Backup-LocalFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
    }

    $date = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = [IO.Path]::GetFileName($Path)
    $backupPath = Join-Path $BackupRoot "$name.$date.backup"
    Move-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    Invoke-WebRequest -Uri $Uri -OutFile $Destination
    Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
}

$repoRoot = Get-RepositoryRoot
$backupRoot = Join-Path $repoRoot $BackupFolderName
$manifestUri = "$($RepositoryRawUri.TrimEnd('/'))/$ManifestPath"

Write-Host "ClaudIA script update manifest: $manifestUri" -ForegroundColor Cyan
$manifest = (Invoke-WebRequest -Uri $manifestUri).Content | ConvertFrom-Json
if (-not $manifest.files) { throw "Manifest '$manifestUri' does not contain a files array." }

$updated = 0
$current = 0
$downloaded = 0
$skipped = 0

foreach ($item in @($manifest.files)) {
    $format = [string]$item.format
    if ($format -ne 'ps1' -and -not $IncludeSupportFiles) {
        $skipped++
        continue
    }

    $directory = [string]$item.directory
    $relativeDir = if ($directory -and $directory -ne 'ROOT') { $directory } else { '' }
    $relativePath = if ($relativeDir) { Join-Path $relativeDir ([string]$item.file) } else { [string]$item.file }
    $localPath = Join-Path $repoRoot $relativePath
    $remoteUri = "$($RepositoryRawUri.TrimEnd('/'))/$($item.URI)"
    $cloudVersion = if ($item.version) { [version]$item.version } else { $null }

    Write-Host ""
    Write-Host "$relativePath" -ForegroundColor White
    if ($cloudVersion) { Write-Host "  Published version: $cloudVersion" -ForegroundColor Gray }

    if (-not (Test-Path -LiteralPath $localPath)) {
        Write-Host "  Local file missing. Downloading..." -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($relativePath, 'Download missing file')) {
            Invoke-DownloadFile -Uri $remoteUri -Destination $localPath
            $downloaded++
        }
        continue
    }

    if ($format -ne 'ps1') {
        Write-Host "  Support file exists." -ForegroundColor Cyan
        $current++
        continue
    }

    $localVersion = Get-LocalScriptVersion -Path $localPath
    if ($localVersion) {
        Write-Host "  Local version:     $localVersion" -ForegroundColor Gray
    } else {
        Write-Host "  Local version:     unavailable" -ForegroundColor DarkYellow
    }

    $needsUpdate = $Force -or -not $localVersion -or ($cloudVersion -and $localVersion -lt $cloudVersion)
    if (-not $needsUpdate) {
        Write-Host "  Already current." -ForegroundColor Green
        $current++
        continue
    }

    if ($PSCmdlet.ShouldProcess($relativePath, 'Backup and download updated script')) {
        $backupPath = Backup-LocalFile -Path $localPath -BackupRoot $backupRoot
        Write-Host "  Backed up to: $backupPath" -ForegroundColor DarkYellow
        Invoke-DownloadFile -Uri $remoteUri -Destination $localPath
        Write-Host "  Updated." -ForegroundColor Green
        $updated++
    }
}

Write-Host ""
Write-Host "Update complete. Updated: $updated. Downloaded: $downloaded. Current: $current. Skipped: $skipped." -ForegroundColor Green


