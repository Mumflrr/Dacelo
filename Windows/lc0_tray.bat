@echo off
:: lc0_tray.bat — Launcher for the lc0 System Tray Server
:: Double-click this file, or right-click → Pin to Start / Pin to Taskbar

:: Navigate to the script directory
cd /d "%~dp0"

:: ── Option A: Conda environment (recommended) ─────────────────────────────
:: Activate the lc0-server conda environment, then launch with pythonw
:: (pythonw suppresses the console window)
call conda activate lc0-server 2>nul
if not errorlevel 1 (
    start "" pythonw lc0_tray.py
    exit /b
)

:: ── Option B: Plain Python fallback ──────────────────────────────────────
:: Used if conda is not installed or the environment doesn't exist yet.
:: To create the environment first, run:
::   conda env create -f environment.yaml
start "" pythonw lc0_tray.py
if errorlevel 1 (
    start "" python lc0_tray.py
)