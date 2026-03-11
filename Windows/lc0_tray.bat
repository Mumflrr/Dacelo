@echo off
:: lc0_tray.bat
::
:: Usage:
::   lc0_tray.bat          -> start the tray app (server auto-starts silently)
::   lc0_tray.bat --stop   -> stop the running server
::
:: To run on Windows startup:
::   Win+R -> shell:startup -> put a shortcut to this .bat file there

cd /d "%~dp0"

:: ── Stop mode ────────────────────────────────────────────────────────────────
if "%~1"=="--stop" (
    python lc0_tray.py --stop
    if errorlevel 1 (
        echo Error stopping server.
        pause
    )
    exit /b
)

:: ── Start mode ───────────────────────────────────────────────────────────────
:: Try conda environment first, then plain pythonw, then python as last resort.
:: pythonw suppresses the console window; python briefly shows one.

where conda >nul 2>&1
if not errorlevel 1 (
    call conda activate lc0-server 2>nul
    if not errorlevel 1 (
        start "" pythonw lc0_tray.py
        exit /b
    )
)

where pythonw >nul 2>&1
if not errorlevel 1 (
    start "" pythonw lc0_tray.py
    exit /b
)

:: Fallback: regular python (console window will flash briefly then close)
start "" python lc0_tray.py