@echo off
rem ===========================================================================
rem Start-ClaudIA.cmd - double-click entry point for the ClaudIA setup wizard.
rem Finds PowerShell 7 (pwsh), offers to install it if missing, then runs
rem Setup-ClaudIA-Wizard.ps1 from the repository root (this file's folder).
rem The native launchers in dist\ (built by tools\Build-WizardExe.ps1) do the
rem same job without a console window.
rem ===========================================================================
setlocal
cd /d "%~dp0"

if not exist "%~dp0Setup-ClaudIA-Wizard.ps1" (
    echo [ERROR] Setup-ClaudIA-Wizard.ps1 was not found next to this file.
    echo         Keep Start-ClaudIA.cmd in the ClaudIA repository root.
    pause
    exit /b 1
)

rem --- Locate pwsh: PATH first, then the default install folder -------------
set "PWSH="
for /f "delims=" %%i in ('where pwsh 2^>nul') do if not defined PWSH set "PWSH=%%i"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"

if not defined PWSH (
    echo PowerShell 7 is required by the ClaudIA wizard and was not found.
    echo.
    choice /c YN /m "Install PowerShell 7 now with winget"
    if errorlevel 2 (
        echo Install it manually from https://aka.ms/powershell then run this file again.
        pause
        exit /b 1
    )
    winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
        set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
    ) else (
        echo [ERROR] PowerShell 7 still not found. Install it manually then re-run.
        pause
        exit /b 1
    )
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-ClaudIA-Wizard.ps1"
set "WIZARD_EXIT=%ERRORLEVEL%"
if not "%WIZARD_EXIT%"=="0" (
    echo.
    echo The wizard exited with an error ^(code %WIZARD_EXIT%^). Read the message above.
    pause
)
endlocal & exit /b %WIZARD_EXIT%
