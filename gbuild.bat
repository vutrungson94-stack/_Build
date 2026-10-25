@echo off
:: gbuild.bat — Windows launcher for gbuild.ps1
:: SYNCHRONIZED with gbuild.ps1 + gbuild (bash) — keep all three in sync.
:: Project-root resolution lives in ONE place (Resolve-BuildProjectRoot /
:: Find-ProjectRoot in gbuild.ps1); this launcher must not duplicate it.
:: Usage:
::   .\_Build\gbuild.bat -Project "G:\path\with spaces"   (portable USB)
::   .\_Build\gbuild.bat                                  (auto-detect)
::   .\_Build\gbuild.bat "G:\path"                        (positional)
::
:: EnableDelayedExpansion is REQUIRED, not cosmetic. cmd.exe expands %VAR% for a
:: whole if/else compound at PARSE time, so the previous `if %errorlevel% equ 0`
:: in the else-branch tested the value left by the FIRST `where pwsh`, never the
:: `where powershell` that ran just above it. The powershell.exe fallback was
:: therefore dead code: a machine with only Windows PowerShell 5.1 - which is
:: present on every supported Windows release - was told "PowerShell/pwsh not
:: found" and exited 1. The bash launcher uses separate statements and worked,
:: so the two launchers also silently disagreed.
setlocal EnableDelayedExpansion

set "GBUILD_DIR=%~dp0"
set "GBUILD_PS1=%GBUILD_DIR%gbuild.ps1"

if not exist "%GBUILD_PS1%" (
    echo [FATAL] gbuild.ps1 not found at: %GBUILD_PS1% 1>&2
    exit /b 1
)

:: Prefer pwsh, fall back to powershell (Windows PowerShell 5.1). Same
:: preference order as the bash launcher's `command -v` chain.
set "PWSH="
where pwsh >nul 2>&1
if !errorlevel! equ 0 set "PWSH=pwsh"

if not defined PWSH (
    where powershell >nul 2>&1
    if !errorlevel! equ 0 set "PWSH=powershell.exe"
)

if not defined PWSH (
    echo [FATAL] PowerShell/pwsh not found. Install from https://github.com/PowerShell/PowerShell 1>&2
    exit /b 1
)

:: %* preserves the original command line including quoted paths with spaces.
:: Using -File with quoted script path handles spaces in GBUILD_DIR (e.g. "TRUNG SON").
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%GBUILD_PS1%" %*
exit /b !errorlevel!
