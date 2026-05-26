<#PSScriptInfo

.VERSION 1.0.0

.GUID 7ff14a5d-03e7-44e1-8d6c-53f28ebf4a8e

.AUTHOR
https://www.linkedin.com/in/profesorkaz/; Sebastian Zamorano
https://www.linkedin.com/in/mrnabster; Nabil Senoussaoui

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA Configuration Backup Restore PowerShell

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Backs up and restores ClaudIA local configuration files while preserving folder structure.

.RELEASENOTES
Initial version metadata for ClaudIA configuration backup and restore.

#>

<#
.SYNOPSIS
    Backs up and restores ClaudIA local configuration files.
.DESCRIPTION
    Creates timestamped backups under the repository root TemporaryBackup folder
    and preserves each configured file or folder path so it can be restored after
    downloading or replacing the full repository.

    By default, the script backs up only the config folder. Use -AdditionalPath
    for other local configuration files that should survive a full folder
    replacement. Browser auth sessions and generated outputs are intentionally
    not included by default.
.PARAMETER Mode
    Backup, Restore, or List. Backup is the default.
.PARAMETER BackupName
    Name of the backup folder to restore. If omitted, Restore uses the latest
    config-backup-* folder under TemporaryBackup.
.PARAMETER AdditionalPath
    Additional relative file or folder paths to include in the backup.
.PARAMETER BackupRoot
    Backup root folder. Defaults to <repo>\TemporaryBackup.
.PARAMETER Force
    Allows restoring over existing files without an interactive confirmation.
.EXAMPLE
    .\tools\Backup-ClaudIAConfiguration.ps1
.EXAMPLE
    .\tools\Backup-ClaudIAConfiguration.ps1 -Mode Restore
.EXAMPLE
    .\tools\Backup-ClaudIAConfiguration.ps1 -Mode Backup -AdditionalPath '.env'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Backup', 'Restore', 'List')]
    [string]$Mode = 'Backup',
    [string]$BackupName = '',
    [string[]]$AdditionalPath = @(),
    [string]$BackupRoot = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function ConvertTo-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' is outside repository root '$Root'."
    }
    return $pathFull.Substring($rootFull.Length)
}

function Copy-PathPreservingStructure {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $source = Join-Path $SourceRoot $RelativePath
    $destination = Join-Path $DestinationRoot $RelativePath
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $source -PathType Container) {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    } elseif (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    } else {
        throw "Path not found: $source"
    }
}

function Get-BackupFolders {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'config-backup-*' |
        Sort-Object LastWriteTime -Descending)
}

function Read-BackupManifest {
    param([Parameter(Mandatory)][string]$BackupPath)

    $manifestPath = Join-Path $BackupPath 'backup-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Backup manifest not found: $manifestPath"
    }
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
}

$repoRoot = Get-RepositoryRoot
if (-not $BackupRoot) { $BackupRoot = Join-Path $repoRoot 'TemporaryBackup' }

$defaultPaths = @('config')
$paths = @($defaultPaths + $AdditionalPath | Where-Object { $_ } | Select-Object -Unique)

switch ($Mode) {
    'List' {
        $folders = Get-BackupFolders -Root $BackupRoot
        if ($folders.Count -eq 0) {
            Write-Host "No configuration backups found under $BackupRoot." -ForegroundColor DarkYellow
            return
        }

        $folders | ForEach-Object {
            $manifestPath = Join-Path $_.FullName 'backup-manifest.json'
            $createdAt = if (Test-Path -LiteralPath $manifestPath) {
                (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json).createdAt
            } else {
                $_.LastWriteTime.ToString('o')
            }
            [PSCustomObject]@{
                BackupName = $_.Name
                CreatedAt = $createdAt
                Path = $_.FullName
            }
        } | Format-Table -AutoSize
        return
    }

    'Backup' {
        if (-not (Test-Path -LiteralPath $BackupRoot)) {
            New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null
        }

        $backupNameValue = "config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $backupPath = Join-Path $BackupRoot $backupNameValue
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null

        $included = @()
        $missing = @()
        foreach ($relativePath in $paths) {
            $source = Join-Path $repoRoot $relativePath
            if (-not (Test-Path -LiteralPath $source)) {
                $missing += $relativePath
                continue
            }

            if ($PSCmdlet.ShouldProcess($relativePath, "Back up to $backupNameValue")) {
                Copy-PathPreservingStructure -SourceRoot $repoRoot -DestinationRoot $backupPath -RelativePath $relativePath
                $included += $relativePath
            }
        }

        $manifest = [ordered]@{
            schemaVersion = '1.0'
            createdAt = (Get-Date).ToString('o')
            backupName = $backupNameValue
            sourceRoot = $repoRoot
            paths = @($included)
            missingPaths = @($missing)
            note = 'After restoring and validating the environment, this TemporaryBackup folder can be deleted.'
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $backupPath 'backup-manifest.json') -Encoding utf8

        Write-Host "Configuration backup created:" -ForegroundColor Green
        Write-Host "  $backupPath"
        if ($missing.Count -gt 0) {
            Write-Host "Missing paths skipped: $($missing -join ', ')" -ForegroundColor DarkYellow
        }
        Write-Host "After restoring and validating the environment, you can delete TemporaryBackup." -ForegroundColor Yellow
        return
    }

    'Restore' {
        $backupPath = if ($BackupName) {
            Join-Path $BackupRoot $BackupName
        } else {
            $latest = Get-BackupFolders -Root $BackupRoot | Select-Object -First 1
            if (-not $latest) { throw "No configuration backups found under $BackupRoot." }
            $latest.FullName
        }

        if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
            throw "Backup folder not found: $backupPath"
        }

        $manifest = Read-BackupManifest -BackupPath $backupPath
        $restorePaths = @($manifest.paths)
        if ($restorePaths.Count -eq 0) { throw "Backup '$backupPath' does not contain paths to restore." }

        Write-Host "Restoring configuration backup:" -ForegroundColor Cyan
        Write-Host "  $backupPath"
        Write-Host "Target repository:"
        Write-Host "  $repoRoot"

        if (-not $Force) {
            $answer = Read-Host "  Restore over current local configuration files? (y/N)"
            if ($answer -notin @('y', 'Y', 'yes', 'YES')) {
                Write-Host "Restore cancelled." -ForegroundColor DarkYellow
                return
            }
        }

        foreach ($relativePath in $restorePaths) {
            $source = Join-Path $backupPath $relativePath
            if (-not (Test-Path -LiteralPath $source)) {
                Write-Warning "Skipping missing backup path: $relativePath"
                continue
            }
            if ($PSCmdlet.ShouldProcess($relativePath, 'Restore configuration path')) {
                Copy-PathPreservingStructure -SourceRoot $backupPath -DestinationRoot $repoRoot -RelativePath $relativePath
                Write-Host "  Restored $relativePath" -ForegroundColor Green
            }
        }

        Write-Host ""
        Write-Host "Configuration restore complete." -ForegroundColor Green
        Write-Host "After validating the restored environment, you can delete TemporaryBackup." -ForegroundColor Yellow
        return
    }
}
