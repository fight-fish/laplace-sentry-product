@echo off
setlocal
chcp 65001 > nul

REM ===================================================
REM Contract:
REM - Purpose: Uninstall installed Laplace Sentry and optionally preserve formal data backup.
REM - Inputs:
REM   1) Windows install dir: %LOCALAPPDATA%\LaplaceSentry
REM   2) Desktop shortcut: %USERPROFILE%\Desktop\Laplace Sentry.lnk
REM   3) WSL runtime dir: ~/.laplace_sentry_backend
REM   4) WSL formal data backup dir: ~/.laplace_sentry_backend_data_backup
REM   5) User input:
REM      - KEEP_DATA = y/n
REM      - CONFIRM   = y
REM - Outputs:
REM   - stdout/stderr messages
REM   - exit code for uninstall flow result
REM - Exit codes:
REM   - 0 = uninstall completed or cancelled by user
REM   - 1 = uninstall failed
REM - Side effects:
REM   - remove desktop shortcut
REM   - remove Windows Frontend installed files
REM   - optionally preserve WSL formal data
REM   - remove WSL backend runtime copy
REM ===================================================

REM [Resolve inputs]
set "WIN_INSTALL_DIR=%LOCALAPPDATA%\LaplaceSentry"
set "DESKTOP_SHORTCUT=%USERPROFILE%\Desktop\Laplace Sentry.lnk"
set "WSL_RUNTIME_DIR=~/.laplace_sentry_backend"
set "WSL_DATA_BACKUP_DIR=~/.laplace_sentry_backend_data_backup"
set "KEEP_DATA="
set "CONFIRM="
set "WSL_AVAILABLE=0"

if "%~1" neq "" set "KEEP_DATA=%~1"
if "%~2" neq "" set "CONFIRM=%~2"

if "%~1"=="" (
    echo ===================================================
    echo      Laplace Sentry - 解除安裝精靈
    echo ===================================================
    echo.
    echo [警告] 此操作將移除：
    echo.
    echo   1. 桌面捷徑
    echo   2. Windows 前端安裝檔
    echo   3. WSL 後端執行副本
    echo.
)

if /i not "%KEEP_DATA%"=="y" if /i not "%KEEP_DATA%"=="n" (
    set /p KEEP_DATA="是否先備份正式資料？(y/n): "
)

if /i not "%CONFIRM%"=="y" if /i not "%CONFIRM%"=="n" (
    set /p CONFIRM="是否繼續解除安裝？(輸入 y 確認): "
)

REM [Decide] 使用者取消 => SKIP(rc=0)
if /i not "%CONFIRM%"=="y" (
    if "%~1"=="" (
        echo [資訊] 已取消解除安裝。
        echo.
        pause
    )
    exit /b 0
)

REM [Hard preflight] 檢查 WSL 可用性
wsl --status > nul 2>&1
if not errorlevel 1 (
    set "WSL_AVAILABLE=1"
)

echo.

REM [Side effects] 1. Remove desktop shortcut
echo [1/4] Removing desktop shortcut...
if exist "%DESKTOP_SHORTCUT%" (
    del "%DESKTOP_SHORTCUT%" > nul 2>&1
    if exist "%DESKTOP_SHORTCUT%" (
        echo [UNINSTALL_FAIL] Failed to remove desktop shortcut. 1>&2
        echo.
        pause
        exit /b 1
    )
    echo    - Shortcut removed.
) else (
    echo    - Shortcut not found. Skipped.
)

REM [Side effects] 2. Remove Windows Frontend installed files
echo [2/4] Removing Windows Frontend installed files...
if exist "%WIN_INSTALL_DIR%" (
    rmdir /s /q "%WIN_INSTALL_DIR%" > nul 2>&1
    if exist "%WIN_INSTALL_DIR%" (
        echo [UNINSTALL_FAIL] Failed to remove Windows install directory. 1>&2
        echo.
        pause
        exit /b 1
    )
    echo    - Windows install directory removed.
) else (
    echo    - Windows install directory not found. Skipped.
)

REM [Deferred validation + Side effects] 3. Preserve formal data if requested
echo [3/4] Handling WSL formal data...
if "%WSL_AVAILABLE%"=="1" (
    if /i "%KEEP_DATA%"=="y" (
        wsl sh -lc "rm -rf %WSL_DATA_BACKUP_DIR% && mkdir -p %WSL_DATA_BACKUP_DIR% && if [ -d %WSL_RUNTIME_DIR%/data ]; then cp -r %WSL_RUNTIME_DIR%/data/. %WSL_DATA_BACKUP_DIR%/; fi"
        if errorlevel 1 (
            echo [UNINSTALL_FAIL] Failed to preserve WSL formal data. 1>&2
            echo.
            pause
            exit /b 1
        )
        echo    - WSL formal data preserved at: %WSL_DATA_BACKUP_DIR%
    ) else (
        echo    - Formal data preservation skipped.
    )
) else (
    echo    - WSL not detected. Formal data step skipped.
)

REM [Side effects] 4. Remove WSL backend runtime copy
echo [4/4] Removing WSL backend runtime copy...
if "%WSL_AVAILABLE%"=="1" (
    wsl sh -lc "rm -rf %WSL_RUNTIME_DIR%"
    if errorlevel 1 (
        echo [UNINSTALL_FAIL] Failed to remove WSL backend runtime copy. 1>&2
        echo.
        pause
        exit /b 1
    )
    echo    - WSL backend runtime copy removed.
) else (
    echo    - WSL not detected. Runtime removal skipped.
)

echo.
echo ===================================================
echo         Uninstall complete.
echo ===================================================
echo.
pause
exit /b 0