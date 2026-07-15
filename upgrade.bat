@echo off
setlocal
chcp 65001 > nul

REM ===================================================
REM Contract:
REM - Purpose: Laplace Sentry single upgrade entrypoint.
REM - Inputs: --dry-run (default), --stage, --staging-root PATH.
REM - Outputs: console plan; stage mode writes only under staging-root.
REM - SSOT Output: scripts\upgrade.ps1 plan/manifest output.
REM - Exit codes: passthrough from scripts\upgrade.ps1.
REM - Side effects: none in dry-run; stage mode never writes formal runtime.
REM ===================================================

REM 這支腳本在做什麼：提供唯一、薄的 Windows 升級入口。
REM 這支腳本不做什麼：不直接複製檔案、不停止程序、不判斷資料政策。
REM 常改區塊：CLI 參數轉接。
REM 不要亂動的區塊：無參數必須維持 dry-run。

set "SCRIPT=%~dp0scripts\upgrade.ps1"

if not exist "%SCRIPT%" (
    echo [UPGRADE_FAIL] Missing upgrade script: "%SCRIPT%" 1>&2
    exit /b 2
)

if "%~1"=="" goto :run_default_dry_run
if /I "%~1"=="--dry-run" goto :run_dry_run
if /I "%~1"=="--stage" goto :run_stage

if /I "%~1"=="--help" goto :usage
if /I "%~1"=="-h" goto :usage

echo [UPGRADE_FAIL] Unknown option: %~1 1>&2
exit /b 2

:run_default_dry_run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode DryRun
exit /b %ERRORLEVEL%

:run_dry_run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode DryRun %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:run_stage
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Stage %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   upgrade.bat                         ^(safe dry-run; default^)
echo   upgrade.bat --dry-run
echo   upgrade.bat --stage -StagingRoot PATH
echo.
echo This first-stage entry never writes the formal Windows or WSL runtime.
exit /b 0
