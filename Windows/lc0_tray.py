"""
lc0_tray.py — System Tray Icon to Start / Stop the lc0 WebSocket Server

Provides a Windows system tray icon with:
  • Start Server
  • Stop Server
  • Open Log
  • Quit

Requirements:
    pip install pystray pillow

Run this script instead of lc0_server.py directly. It manages the server
as a subprocess, so you can toggle it on/off without closing the tray app.

To add to Startup:
  Press Win+R → shell:startup → copy the shortcut to lc0_tray.py here,
  or use the included lc0_tray.bat launcher.
"""

import subprocess
import sys
import os
import threading
import webbrowser
from pathlib import Path

import pystray
from pystray import MenuItem, Menu
from PIL import Image, ImageDraw

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "lc0_server.py"
CONFIG_FILE   = SCRIPT_DIR / "lc0_config.txt"
LOG_FILE      = SCRIPT_DIR / "lc0_server.log"

PYTHON_EXE = sys.executable  # same interpreter that runs this tray script

# Read config or use defaults
def load_config() -> dict:
    config = {
        "lc0": r"C:\lc0\lc0.exe",
        "port": "8765",
        "threads": "4",
        "weights": "",
    }
    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text().splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                config[k.strip()] = v.strip()
    return config


# ── Tray Icon Image ───────────────────────────────────────────────────────────

def make_icon(running: bool) -> Image.Image:
    """Draw a simple chess-knight-ish square icon. Green = running, grey = stopped."""
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    color = (34, 197, 94) if running else (107, 114, 128)   # green or grey
    draw.rectangle([4, 4, size - 4, size - 4], fill=color, outline="white", width=3)
    # Draw a tiny 'L' for Leela
    draw.text((18, 14), "L\nC0", fill="white")
    return img


# ── Server Process Manager ────────────────────────────────────────────────────

class ServerManager:
    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()

    @property
    def running(self) -> bool:
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    def start(self):
        with self._lock:
            if self._proc and self._proc.poll() is None:
                return  # already running
            cfg = load_config()
            cmd = [PYTHON_EXE, str(SERVER_SCRIPT),
                   "--lc0", cfg["lc0"],
                   "--port", cfg["port"],
                   "--threads", cfg["threads"]]
            if cfg["weights"]:
                cmd += ["--weights", cfg["weights"]]

            # Open a new console window so you can see output (remove creationflags to hide)
            self._proc = subprocess.Popen(
                cmd,
                creationflags=subprocess.CREATE_NO_WINDOW,  # silent background
            )

    def stop(self):
        with self._lock:
            if self._proc and self._proc.poll() is None:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
            self._proc = None


# ── Tray App ──────────────────────────────────────────────────────────────────

manager = ServerManager()

def on_start(icon, item):
    manager.start()
    icon.icon = make_icon(True)
    icon.title = "lc0 Server — Running"

def on_stop(icon, item):
    manager.stop()
    icon.icon = make_icon(False)
    icon.title = "lc0 Server — Stopped"

def on_open_log(icon, item):
    if LOG_FILE.exists():
        webbrowser.open(str(LOG_FILE))

def on_quit(icon, item):
    manager.stop()
    icon.stop()

def build_menu(icon):
    return Menu(
        MenuItem("▶  Start Server",  on_start,  enabled=lambda i: not manager.running),
        MenuItem("⏹  Stop Server",   on_stop,   enabled=lambda i: manager.running),
        Menu.SEPARATOR,
        MenuItem("📄  Open Log",      on_open_log),
        Menu.SEPARATOR,
        MenuItem("✕  Quit",           on_quit),
    )

def main():
    icon = pystray.Icon(
        name="lc0_server",
        icon=make_icon(False),
        title="lc0 Server — Stopped",
        menu=pystray.Menu(
            pystray.MenuItem("▶  Start Server",  on_start,  enabled=lambda i: not manager.running),
            pystray.MenuItem("⏹  Stop Server",   on_stop,   enabled=lambda i: manager.running),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("📄  Open Log",      on_open_log),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("✕  Quit",           on_quit),
        )
    )

    # Auto-start on launch
    manager.start()
    icon.icon = make_icon(True)
    icon.title = "lc0 Server — Running"

    icon.run()


if __name__ == "__main__":
    main()