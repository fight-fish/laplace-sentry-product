@echo off
cd /d "%~dp0"
call .venv\Scripts\activate
start "Sentry UI" pythonw -m src.tray.tray_app
exit