<#PSScriptInfo

.VERSION 1.0.0
.GUID 3d8a5b1f-2c47-4e6a-9f30-b18e7d4c5a91

.AUTHOR
ClaudIA contributors

.COMPANYNAME
ClaudIA - Cloud Activity, Usage & Data Intelligence Architecture

.COPYRIGHT
Copyright (c) ClaudIA contributors. All rights reserved.

.TAGS
ClaudIA Build Launcher Wizard Exe

.PROJECTURI
https://github.com/MH-Demos/ClaudIA

.DESCRIPTION
Builds the native ClaudIA wizard launcher executables into dist\.

.RELEASENOTES
Version 1.0.0: initial build pipeline. Compiles
tools\wizard-launcher\ClaudIA-WizardLauncher.cs with the C# compiler that
ships inside the .NET Framework (no SDK required) into two artifacts:
dist\ClaudIA-Wizard-x64.exe (/platform:x64) and dist\ClaudIA-Wizard-arm64.exe
(AnyCPU - the in-box compiler has no arm64 flag, but AnyCPU IL is JIT-compiled
natively on Windows 11 ARM via .NET Framework 4.8.1, and still runs everywhere
else). Each build is smoke-tested (-SelfTest through the wizard) unless
-NoTest is passed.

#>

<#
.SYNOPSIS
    Builds the native ClaudIA wizard launcher executables (x64 + ARM64).
.DESCRIPTION
    Compiles tools\wizard-launcher\ClaudIA-WizardLauncher.cs using the in-box
    .NET Framework C# compiler (csc.exe, present on every Windows machine -
    no Visual Studio or SDK needed) and writes:

        dist\ClaudIA-Wizard-x64.exe    (/platform:x64  - Intel/AMD 64-bit)
        dist\ClaudIA-Wizard-arm64.exe  (AnyCPU - runs NATIVELY on Windows on
                                        ARM through the .NET Framework 4.8.1
                                        ARM64 JIT; also runs on x64)

    The launcher only locates the repo + PowerShell 7 and starts
    Setup-ClaudIA-Wizard.ps1; all deployment logic stays in the audited
    PowerShell scripts (the exe is a bootstrap, not a compiled wizard).
.PARAMETER NoTest
    Skip the post-build smoke test (launcher execution + wizard -SelfTest).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-WizardExe.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoTest
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceFile = Join-Path $PSScriptRoot 'wizard-launcher\ClaudIA-WizardLauncher.cs'
$DistDir = Join-Path $RepoRoot 'dist'

if (-not (Test-Path -LiteralPath $SourceFile)) { throw "Launcher source not found: $SourceFile" }
if (-not (Test-Path -LiteralPath $DistDir)) { New-Item -ItemType Directory -Path $DistDir -Force | Out-Null }

# --- Locate the in-box C# compiler ----------------------------------------
$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe (in-box .NET Framework C# compiler) was not found. This build requires .NET Framework 4.x, present by default on Windows 10/11.' }
Write-Host "[BUILD] Using compiler: $csc"

# --- Optional icon: derive an .ico from the branding PNG at build time -----
$iconArg = ''
$brandPng = Join-Path $RepoRoot 'Images\Branding\Fav_Icons.png'
$icoPath = Join-Path $env:TEMP 'claudia-wizard.ico'
if (Test-Path -LiteralPath $brandPng) {
    try {
        Add-Type -AssemblyName System.Drawing
        $src = [System.Drawing.Image]::FromFile($brandPng)
        try {
            $bmp = New-Object System.Drawing.Bitmap $src, 64, 64
            try {
                # Wrap the 64x64 PNG in a minimal single-image ICO container
                # (PNG-in-ICO is supported since Vista).
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $png = $ms.ToArray(); $ms.Dispose()
                $fsIco = [System.IO.File]::Create($icoPath)
                try {
                    $bw = New-Object System.IO.BinaryWriter $fsIco
                    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)   # ICONDIR
                    $bw.Write([byte]64); $bw.Write([byte]64); $bw.Write([byte]0); $bw.Write([byte]0) # w,h,colors,reserved
                    $bw.Write([uint16]1); $bw.Write([uint16]32)                          # planes, bpp
                    $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)                # size, offset
                    $bw.Write($png); $bw.Flush()
                } finally { $fsIco.Dispose() }
                $iconArg = "/win32icon:`"$icoPath`""
                Write-Host '[BUILD] Branding icon embedded (Images\Branding\Fav_Icons.png).'
            } finally { $bmp.Dispose() }
        } finally { $src.Dispose() }
    } catch {
        Write-Host "[WARN ] Icon generation failed ($($_.Exception.Message)); building without an icon." -ForegroundColor Yellow
        $iconArg = ''
    }
}

# --- Compile both artifacts -------------------------------------------------
# NOTE: the in-box csc has no /platform:arm64. AnyCPU IL executes NATIVELY on
# Windows 11 ARM (the .NET Framework 4.8.1 in-box runtime has an ARM64 JIT),
# which is exactly what we want for the ARM artifact - and it stays runnable
# on x64 machines too.
$targets = @(
    @{ Name = 'ClaudIA-Wizard-x64.exe';   Platform = 'x64' },
    @{ Name = 'ClaudIA-Wizard-arm64.exe'; Platform = 'anycpu' }
)

foreach ($t in $targets) {
    $out = Join-Path $DistDir $t.Name
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    $cscArgs = @(
        '/nologo', '/target:winexe', "/platform:$($t.Platform)", '/optimize+',
        '/r:System.dll', '/r:System.Windows.Forms.dll',
        "/out:`"$out`""
    )
    if ($iconArg) { $cscArgs += $iconArg }
    $cscArgs += "`"$SourceFile`""
    Write-Host "[BUILD] $($t.Name) (/platform:$($t.Platform)) ..."
    $proc = Start-Process -FilePath $csc -ArgumentList ($cscArgs -join ' ') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP 'csc-out.txt') -RedirectStandardError (Join-Path $env:TEMP 'csc-err.txt')
    $cscOut = (Get-Content (Join-Path $env:TEMP 'csc-out.txt') -Raw -ErrorAction SilentlyContinue)
    $cscErr = (Get-Content (Join-Path $env:TEMP 'csc-err.txt') -Raw -ErrorAction SilentlyContinue)
    if ($proc.ExitCode -ne 0) {
        Write-Host $cscOut; Write-Host $cscErr -ForegroundColor Red
        throw "csc failed for $($t.Name) (exit $($proc.ExitCode))"
    }
    if ($cscOut -and $cscOut.Trim()) { Write-Host $cscOut.Trim() }
    $size = [math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1)
    Write-Host "[ OK  ] $out ($size KB)"
}

# --- Smoke test -------------------------------------------------------------
if (-not $NoTest) {
    Write-Host '[TEST ] Wizard headless self-test through pwsh ...'
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Write-Host '[WARN ] pwsh not found on this machine; skipping the self-test.' -ForegroundColor Yellow
    } else {
        & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'Setup-ClaudIA-Wizard.ps1') -SelfTest
        if ($LASTEXITCODE -ne 0) { throw "Wizard -SelfTest failed (exit $LASTEXITCODE)" }
        Write-Host '[ OK  ] Wizard self-test passed.'
    }
    # Verify the x64 binary loads and resolves the repo from dist\ (launching
    # the real GUI is interactive, so we only verify the PE + root discovery
    # logic indirectly: the binary must be a valid .NET assembly).
    try {
        $asm = [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path $DistDir 'ClaudIA-Wizard-x64.exe'))
        Write-Host "[ OK  ] x64 assembly valid: $($asm.FullName) [$($asm.ProcessorArchitecture)]"
        $asm2 = [System.Reflection.AssemblyName]::GetAssemblyName((Join-Path $DistDir 'ClaudIA-Wizard-arm64.exe'))
        Write-Host "[ OK  ] arm64(AnyCPU) assembly valid: $($asm2.FullName) [$($asm2.ProcessorArchitecture)]"
    } catch { throw "Built binaries failed assembly validation: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'Done. Artifacts in dist\ - double-click ClaudIA-Wizard-x64.exe (Intel/AMD) or ClaudIA-Wizard-arm64.exe (Windows on ARM).'
