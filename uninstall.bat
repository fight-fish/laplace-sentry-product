@echo off
chcp 65001 > nul
setlocal

echo ===================================================
echo      Laplace Sentry - 一鍵移除精靈
echo ===================================================
echo.
echo [警告] 此操作將會執行「完全清理」，包含：
echo.
echo   1. 移除桌面捷徑
echo   2. 刪除 Windows 前端程式
echo   3. 刪除 WSL 後端程式
echo.
set /p confirm="您確定要繼續嗎？(請輸入 y 確認): "
if /i "%confirm%" neq "y" (
    echo 操作已取消。
    pause
    exit /b
)

echo.

:: 1. 刪除桌面捷徑
echo [1/3] 正在移除桌面捷徑...
if exist "%USERPROFILE%\Desktop\Laplace Sentry.lnk" (
    del "%USERPROFILE%\Desktop\Laplace Sentry.lnk"
    echo    - 捷徑已刪除。
) else (
    echo    - 捷徑不存在，跳過。
)

:: 2. 刪除 Windows 前端檔案
echo [2/3] 正在移除前端檔案...
if exist "%LOCALAPPDATA%\LaplaceSentry" (
    rmdir /s /q "%LOCALAPPDATA%\LaplaceSentry"
    echo    - 前端目錄已清除。
) else (
    echo    - 前端目錄不存在，跳過。
)

:: 3. 刪除 WSL 後端檔案
echo [3/3] 正在移除 WSL 後端檔案...
wsl --status > nul 2>&1
if %errorlevel% equ 0 (
    wsl rm -rf ~/.laplace_sentry_backend
    echo    - 後端目錄已清除。
) else (
    echo [警告] 未偵測到 WSL，無法清理後端檔案。
)

echo.
echo ===================================================
echo         移除完成。
echo ===================================================
echo.
pause