@echo off
setlocal

REM ===================================================
REM Contract:
REM - Purpose: 啟動 Windows 工作樹中的 Sentry UI 開發版入口
REM - Inputs:
REM   1) 本 bat 所在目錄
REM   2) .venv\Scripts\activate.bat
REM   3) python module: src.tray.tray_app
REM - Outputs:
REM   - stdout/stderr 訊息
REM   - exit code 與 python 執行結果同源
REM - SSOT Output:
REM   - 無獨立落盤；以 python process exit code 為本次結果真相
REM - Exit codes:
REM   - 0 = Python UI 行程正常結束
REM   - 1 = 前置條件失敗（例如工作目錄切換失敗、找不到 .venv、啟用失敗）
REM   - 其餘 = 原樣透傳 Python exit code
REM - SKIP 條件（rc=0）:
REM   - 無
REM - FAIL 條件（rc!=0）:
REM   - 工作目錄切換失敗
REM   - 虛擬環境不存在
REM   - activate.bat 執行失敗
REM   - Python 啟動失敗或程式本身返回非 0
REM - Side effects:
REM   - 切換目前工作目錄
REM   - 啟用虛擬環境
REM   - 啟動 Python UI 程序（前台阻塞，直到程式結束）
REM ===================================================

REM [Hard preflight] 設定 UTF-8
chcp 65001 > nul

REM [Resolve inputs] 切到 bat 所在目錄
cd /d "%~dp0" || (
    echo [BOOT_FAIL] 無法切換到腳本所在目錄: "%~dp0" 1>&2
    exit /b 1
)

REM [Hard preflight] 檢查虛擬環境啟動腳本是否存在
if not exist ".venv\Scripts\activate.bat" (
    echo [BOOT_FAIL] 找不到虛擬環境: ".venv\Scripts\activate.bat" 1>&2
    exit /b 1
)

echo ===================================================
echo      Laplace Sentry UI - DEV MODE
echo ===================================================
echo.
echo [DEV] Launching Frontend from Windows working tree.
echo [DEV] This entry does not overwrite installed files.
echo [DEV] This entry does not run the upgrade flow.
echo.

REM [Side effects] 啟用虛擬環境
call ".venv\Scripts\activate.bat"
if errorlevel 1 (
    echo [BOOT_FAIL] 虛擬環境啟用失敗。 1>&2
    exit /b 1
)

REM [Side effects + Exit code] 啟動 UI，並透傳 Python exit code
python -m src.tray.tray_app
set "RC=%ERRORLEVEL%"

endlocal & exit /b %RC%