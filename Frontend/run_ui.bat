@echo off
setlocal

REM ===================================================
REM Contract:
REM - Purpose: 啟動已安裝位置中的 Sentry UI 正式入口
REM - Inputs:
REM   1) 本 bat 所在目錄
REM   2) 預期安裝根目錄: %LOCALAPPDATA%\LaplaceSentry
REM   3) .venv\Scripts\activate.bat
REM   4) pythonw module: src.tray.tray_app
REM - Outputs:
REM   - stdout/stderr 訊息
REM   - exit code 表示入口檢查與啟動指令是否成功發出
REM - SSOT Output:
REM   - 無獨立落盤；以本入口腳本 exit code 表示本次入口處理結果
REM - Exit codes:
REM   - 0 = 已通過前置檢查，並成功發出 UI 啟動命令
REM 　- 1 = 入口檢查或啟動命令失敗
REM - SKIP 條件（rc=0）:
REM   - 無
REM - FAIL 條件（rc!=0）:
REM   - 非安裝版 Frontend 位置執行
REM   - 工作目錄切換失敗
REM   - 虛擬環境不存在
REM   - activate.bat 執行失敗
REM   - start / pythonw 啟動命令發出失敗
REM - Side effects:
REM   - 切換目前工作目錄
REM   - 啟用虛擬環境
REM   - 以分離式方式啟動 Python UI 行程
REM ===================================================

REM [Hard preflight] 設定 UTF-8
chcp 65001 > nul

REM [Resolve inputs] 切到 bat 所在目錄
cd /d "%~dp0" || (
    echo [BOOT_FAIL] 無法切換到腳本所在目錄: "%~dp0" 1>&2
    exit /b 1
)

REM [Resolve inputs] 設定路徑
set "INSTALL_ROOT=%LOCALAPPDATA%\LaplaceSentry"
set "CURRENT_ROOT=%~dp0"

REM [Normalize] 移除尾端反斜線後再比較
if "%CURRENT_ROOT:~-1%"=="\" set "CURRENT_ROOT=%CURRENT_ROOT:~0,-1%"
if "%INSTALL_ROOT:~-1%"=="\" set "INSTALL_ROOT=%INSTALL_ROOT:~0,-1%"

REM [Hard preflight] 僅允許安裝版位置使用本入口
if /I not "%CURRENT_ROOT%"=="%INSTALL_ROOT%" (
    echo ===================================================
    echo      Laplace Sentry UI - ENTRY NOTICE
    echo ===================================================
    echo.
    echo [INFO] This run_ui.bat is reserved for the installed app entry.
    echo [INFO] Current location is not the installed Frontend copy.
    echo [INFO] For working tree testing, use run_dev_ui.bat instead.
    echo.
    exit /b 1
)

REM [Hard preflight] 檢查虛擬環境啟動腳本是否存在
if not exist ".venv\Scripts\activate.bat" (
    echo [BOOT_FAIL] 找不到虛擬環境: ".venv\Scripts\activate.bat" 1>&2
    exit /b 1
)

REM [Side effects] 啟用虛擬環境
call ".venv\Scripts\activate.bat"
if errorlevel 1 (
    echo [BOOT_FAIL] 虛擬環境啟用失敗。 1>&2
    exit /b 1
)

REM [Side effects + Exit code] 分離式啟動 UI
start "Sentry UI" pythonw -m src.tray.tray_app
if errorlevel 1 (
    echo [BOOT_FAIL] 無法發出 UI 啟動命令。 1>&2
    exit /b 1
)

endlocal & exit /b 0