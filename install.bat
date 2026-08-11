@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

echo ===================================================
echo      Laplace Sentry Control - One-click Installer
echo ===================================================
echo.

:: 1. Check WSL availability
echo [1/5] Checking WSL environment...
wsl --status > nul 2>&1
if %errorlevel% neq 0 (
    echo [INSTALL_FAIL] WSL was not detected. Please install WSL2 + Ubuntu first. 1>&2
    pause
    exit /b 1
)
echo [OK] WSL is available.

:: 2. Resolve paths
set "BACKEND_SRC=%~dp0Backend"
set "FRONTEND_SRC=%~dp0Frontend"
set "INSTALL_DIR_WIN=%LOCALAPPDATA%\LaplaceSentry"
set "WSL_DEST_DIR=~/.laplace_sentry_backend"
set "WIN_VERSION_FILE=%INSTALL_DIR_WIN%\version.txt"
set "WSL_VERSION_FILE=%WSL_DEST_DIR%/version.txt"
set "BUILD_VERSION=unknown"

for /f %%i in ('git rev-parse --short HEAD 2^>nul') do set "BUILD_VERSION=%%i"
if /I "%BUILD_VERSION%"=="unknown" (
    for /f %%i in ('powershell -NoProfile -Command "[DateTime]::UtcNow.ToString(\"yyyyMMdd-HHmmss\")"') do set "BUILD_VERSION=%%i"
)

:: 2.5 First-install guard
if exist "%INSTALL_DIR_WIN%\run_ui.bat" (
    echo [ERROR] Existing Windows installed copy detected:
    echo         "%INSTALL_DIR_WIN%"
    echo [INFO] install.bat is now first-install only.
    echo [INFO] Use the formal upgrade flow for updates.
    pause
    exit /b 1
)

wsl test -f %WSL_DEST_DIR%/main.py
if %errorlevel% equ 0 (
    echo [ERROR] Existing WSL backend runtime copy detected:
    echo         %WSL_DEST_DIR%
    echo [INFO] install.bat is now first-install only.
    echo [INFO] Use the formal upgrade flow for updates.
    pause
    exit /b 1
)

:: 3. Deploy backend to WSL
echo [2/5] Deploying backend to WSL (%WSL_DEST_DIR%)...

for /f "delims=" %%i in ('wsl wslpath "%BACKEND_SRC%"') do set "BACKEND_SRC_WSL=%%i"

wsl sh -lc "mkdir -p %WSL_DEST_DIR%"
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to create WSL backend directory. 1>&2
    pause
    exit /b 1
)

wsl sh -lc "cp -r \"%BACKEND_SRC_WSL%\"/. %WSL_DEST_DIR%/"
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to copy backend files to WSL. 1>&2
    pause
    exit /b 1
)

wsl sh -lc "printf '%%s\n' '%BUILD_VERSION%' > %WSL_VERSION_FILE%"
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to write WSL version.txt. 1>&2
    pause
    exit /b 1
)

:: 4. Initialize backend environment
echo [3/5] Initializing backend Python environment...
echo    - Creating venv...
wsl --cd %WSL_DEST_DIR% python3 -m venv .venv
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to create backend venv. 1>&2
    pause
    exit /b 1
)

echo    - Installing backend dependencies...
wsl --cd %WSL_DEST_DIR% .venv/bin/pip install -r requirements.txt
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to install backend requirements. 1>&2
    pause
    exit /b 1
)

echo [OK] Backend deployment completed.

:: 5. Deploy frontend to Windows
echo [4/5] Deploying frontend to %INSTALL_DIR_WIN%...
if not exist "%INSTALL_DIR_WIN%" mkdir "%INSTALL_DIR_WIN%"
xcopy /E /I /Y "%FRONTEND_SRC%" "%INSTALL_DIR_WIN%" > nul
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to copy frontend files. 1>&2
    pause
    exit /b 1
)

> "%WIN_VERSION_FILE%" echo %BUILD_VERSION%

echo    - Creating frontend Python environment...
cd /d "%INSTALL_DIR_WIN%"
python -m venv .venv
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to create frontend venv. 1>&2
    pause
    exit /b 1
)

echo    - Installing PySide6 requirements...
call .\.venv\Scripts\activate.bat
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to activate frontend venv. 1>&2
    pause
    exit /b 1
)

pip install -r requirements.txt
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to install frontend requirements. 1>&2
    pause
    exit /b 1
)

echo [OK] Frontend deployment completed.

:: 6. Create desktop shortcut
echo [5/5] Creating desktop shortcut...
set "SHORTCUT_SCRIPT=%temp%\CreateShortcut.vbs"
echo Set oWS = WScript.CreateObject("WScript.Shell") > "%SHORTCUT_SCRIPT%"
echo sLinkFile = "%USERPROFILE%\Desktop\Laplace Sentry.lnk" >> "%SHORTCUT_SCRIPT%"
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> "%SHORTCUT_SCRIPT%"
echo oLink.TargetPath = "%INSTALL_DIR_WIN%\run_ui.vbs" >> "%SHORTCUT_SCRIPT%"
echo oLink.WorkingDirectory = "%INSTALL_DIR_WIN%" >> "%SHORTCUT_SCRIPT%"
echo oLink.Description = "Launch Laplace Sentry" >> "%SHORTCUT_SCRIPT%"
echo oLink.IconLocation = "%INSTALL_DIR_WIN%\assets\icons\cyber-eye.ico" >> "%SHORTCUT_SCRIPT%"
echo oLink.Save >> "%SHORTCUT_SCRIPT%"
cscript /nologo "%SHORTCUT_SCRIPT%"
if errorlevel 1 (
    echo [INSTALL_FAIL] Failed to create desktop shortcut. 1>&2
    del "%SHORTCUT_SCRIPT%" > nul 2>&1
    pause
    exit /b 1
)
del "%SHORTCUT_SCRIPT%"

echo.
echo ===================================================
echo         Installation completed successfully.
echo ===================================================
echo.
echo You can now launch [Laplace Sentry] from the desktop shortcut.
echo.
pause