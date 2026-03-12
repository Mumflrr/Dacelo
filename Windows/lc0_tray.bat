@echo off
:: lc0_tray.bat
::
:: Usage:
::   lc0_tray.bat          -> start the tray app (server visible in terminal)
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

:: ── Start mode (debug: visible terminal window) ───────────────────────────────
:: Runs lc0_server.py directly so you can see all output.
:: Press Ctrl+C or type "quit" to stop.

where conda >nul 2>&1
if not errorlevel 1 (
    call conda activate lc0-server 2>nul
    if not errorlevel 1 (
        python lc0_server.py ^
            --lc0=lc0\lc0.exe ^
            --weights=lc0\BT4-332.pb ^
            --port=8765 ^
            --threads=4
        pause
        exit /b
    )
)

python lc0_server.py ^
    --lc0=lc0\lc0.exe ^
    --weights=lc0\BT4-332.pb ^
    --port=8765 ^
    --threads=4

pause