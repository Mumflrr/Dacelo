@echo off
:: dacelo_server.bat
::
:: Launcher for the Dacelo Server GUI (dacelo_server_gui.py).
::
:: Pin this .bat file to your taskbar or Start Menu, or drop a shortcut
:: to it in shell:startup to auto-start with Windows.
::
:: Usage:
::   dacelo_server.bat          -- open the GUI (starts server per saved config)
::   dacelo_server.bat --stop   -- stop the running server and exit
::
:: To run headlessly (server starts, GUI minimizes to tray):
::   Set "Minimize to tray on launch" in the GUI's Server tab, then use
::   dacelo_server.bat from your startup folder.

cd /d "%~dp0"

:: ── Stop mode ─────────────────────────────────────────────────────────────────
if "%~1"=="--stop" (
    python dacelo_server_gui.py --stop
    exit /b
)

:: ── GUI mode ──────────────────────────────────────────────────────────────────
:: pythonw suppresses the console window so only the GUI appears.
:: Falls back to python if pythonw is not on PATH (e.g. some conda envs).

where pythonw >nul 2>&1
if not errorlevel 1 (
    start "" pythonw dacelo_server_gui.py
    exit /b
)

:: pythonw not found — use python (console window will flash briefly)
start "" python dacelo_server_gui.py
