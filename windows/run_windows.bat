@echo off
setlocal
cd /d "%~dp0"

where py >nul 2>nul
if %errorlevel%==0 (
    set "PY=py -3"
) else (
    set "PY=python"
)

%PY% -m pip install -r requirements.txt
if errorlevel 1 (
    echo.
    echo Failed to install dependencies. Please check Python and pip.
    pause
    exit /b 1
)

%PY% src\417ssh_qt.py
pause
