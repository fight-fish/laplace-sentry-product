@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

echo ===================================================
echo      Laplace Sentry Control - 一鍵安裝精靈
echo ===================================================
echo.

:: 1. 檢查 WSL 是否存在
echo [1/5] 檢查 WSL 環境...
wsl --status > nul 2>&1
if %errorlevel% neq 0 (
    echo [錯誤] 未偵測到 WSL！請先安裝 WSL2 - Ubuntu 再執行此安裝包。
    pause
    exit /b 1
)
echo [OK] WSL 運作中。

:: 2. 定義路徑
set "BACKEND_SRC=%~dp0Backend"
set "FRONTEND_SRC=%~dp0Frontend"
set "INSTALL_DIR_WIN=%LOCALAPPDATA%\LaplaceSentry"
set "WSL_DEST_DIR=~/.laplace_sentry_backend"

:: 3. 部署後端 (WSL)
echo [2/5] 正在部署後端至 WSL (%WSL_DEST_DIR%)...
:: 建立目錄
wsl mkdir -p %WSL_DEST_DIR%
:: 複製檔案 (使用 wslpath 轉換路徑)
wsl cp -r "$(wslpath '%BACKEND_SRC%')/"* %WSL_DEST_DIR%/

:: 4. 初始化後端環境
echo [3/5] 正在建立後端 Python 虛擬環境...
echo    - 建立 venv...
wsl --cd %WSL_DEST_DIR% python3 -m venv .venv
echo    - 安裝依賴...
wsl --cd %WSL_DEST_DIR% .venv/bin/pip install -r requirements.txt
echo [OK] 後端部署完成。

:: 5. 部署前端 (Windows)
echo [4/5] 正在部署前端至 %INSTALL_DIR_WIN%...
if not exist "%INSTALL_DIR_WIN%" mkdir "%INSTALL_DIR_WIN%"
xcopy /E /I /Y "%FRONTEND_SRC%" "%INSTALL_DIR_WIN%" > nul

echo    - 正在建立前端 Python 環境 (這需要一點時間)...
cd /d "%INSTALL_DIR_WIN%"
python -m venv .venv
echo    - 正在安裝 PySide6 (請耐心等待)...
call .\.venv\Scripts\activate.bat
pip install -r requirements.txt
echo [OK] 前端部署完成。

:: 6. 建立正式無黑窗啟動器與桌面捷徑
echo [5/5] 正在建立正式啟動器與桌面捷徑...

set "UI_LAUNCHER_VBS=%INSTALL_DIR_WIN%\run_ui.vbs"
if not exist "%UI_LAUNCHER_VBS%" (
    echo [錯誤] 缺少正式 UI 啟動器：%UI_LAUNCHER_VBS%
    echo [提示] 請確認 Frontend\run_ui.vbs 已存在於安裝來源中。
    pause
    exit /b 1
)

set "SHORTCUT_SCRIPT=%temp%\CreateShortcut.vbs"
echo Set oWS = WScript.CreateObject("WScript.Shell") > "%SHORTCUT_SCRIPT%"
echo sLinkFile = "%USERPROFILE%\Desktop\Laplace Sentry.lnk" >> "%SHORTCUT_SCRIPT%"
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> "%SHORTCUT_SCRIPT%"
echo oLink.TargetPath = "%INSTALL_DIR_WIN%\run_ui.vbs" >> "%SHORTCUT_SCRIPT%"
echo oLink.WorkingDirectory = "%INSTALL_DIR_WIN%" >> "%SHORTCUT_SCRIPT%"
echo oLink.Description = "啟動目錄哨兵" >> "%SHORTCUT_SCRIPT%"
echo oLink.IconLocation = "%INSTALL_DIR_WIN%\assets\icons\cyber-eye.ico" >> "%SHORTCUT_SCRIPT%"
echo oLink.Save >> "%SHORTCUT_SCRIPT%"
cscript /nologo "%SHORTCUT_SCRIPT%"
del "%SHORTCUT_SCRIPT%"

echo.
echo ===================================================
echo         🎉 安裝完成！ 🎉
echo ===================================================
echo.
echo 您現在可以點擊桌面上的 [Laplace Sentry] 來啟動程式。
echo.
pause