"""
lc0_tray.py — System Tray for the lc0 WebSocket Server

Usage:
    pythonw lc0_tray.py          # start tray (server auto-starts, no console)
    python  lc0_tray.py --stop   # stop a running server and exit

Requirements:
    pip install pystray pillow

To start on Windows login:
    Win+R → shell:startup → drop a shortcut to lc0_tray.bat there.
"""

import subprocess, sys, os, threading, time, ctypes
from pathlib import Path
import pystray
from PIL import Image, ImageDraw, ImageFont

# ── Configuration — edit these lines ─────────────────────────────────────────
LC0_EXE     = Path(__file__).parent / r"lc0\lc0.exe"
LC0_WEIGHTS = Path(__file__).parent / r"lc0\BT4-332.pb"
LC0_PORT    = 8765
LC0_THREADS = 4
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "lc0_server.py"
LOG_FILE      = SCRIPT_DIR / "lc0_server.log"
PID_FILE      = SCRIPT_DIR / "lc0_server.pid"
PYTHON_EXE    = sys.executable


# ── PID file helpers ──────────────────────────────────────────────────────────

def _write_pid(pid: int):
    PID_FILE.write_text(str(pid))

def _read_pid() -> int | None:
    try:
        return int(PID_FILE.read_text().strip())
    except Exception:
        return None

def _clear_pid():
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass

def _pid_alive(pid: int) -> bool:
    """
    Check if a process is alive by opening it with SYNCHRONIZE and calling
    WaitForSingleObject with a 0 timeout.
      WAIT_TIMEOUT  (0x102) → process is still running
      WAIT_OBJECT_0 (0x000) → process has exited
      WAIT_FAILED   (0xFFFFFFFF) → no such process / access denied
    """
    SYNCHRONIZE = 0x00100000
    WAIT_TIMEOUT = 0x00000102
    k32 = ctypes.windll.kernel32
    handle = k32.OpenProcess(SYNCHRONIZE, False, pid)
    if not handle:
        return False
    result = k32.WaitForSingleObject(handle, 0)
    k32.CloseHandle(handle)
    return result == WAIT_TIMEOUT   # still running

def _terminate_pid(pid: int, timeout: float = 5.0):
    """
    Graceful termination first (CTRL_BREAK_EVENT to the process group),
    then force-kill if it doesn't exit within timeout seconds.
    """
    PROCESS_TERMINATE = 0x0001
    SYNCHRONIZE       = 0x00100000
    WAIT_TIMEOUT_CODE = 0x00000102
    k32 = ctypes.windll.kernel32

    # Send CTRL_BREAK so Python's KeyboardInterrupt / asyncio runs cleanup
    try:
        os.kill(pid, ctypes.c_int(1).value)  # CTRL_BREAK_EVENT = 1
    except (OSError, PermissionError):
        pass

    # Wait up to timeout for graceful exit
    h = k32.OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE, False, pid)
    if not h:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if k32.WaitForSingleObject(h, 100) != WAIT_TIMEOUT_CODE:
            k32.CloseHandle(h)
            return   # exited cleanly
    # Still alive — force kill
    k32.TerminateProcess(h, 1)
    k32.CloseHandle(h)


# ── Tray icon ─────────────────────────────────────────────────────────────────

def make_icon(running: bool) -> Image.Image:
    size, pad = 64, 5
    img   = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw  = ImageDraw.Draw(img)
    bg    = (34, 197, 94) if running else (80, 80, 90)
    shade = (16, 120, 48) if running else (50, 50, 58)
    draw.rounded_rectangle([pad, pad, size - pad, size - pad], radius=10, fill=bg)
    draw.rounded_rectangle([pad + 4, size - pad - 10, size - pad - 4, size - pad - 2],
                            radius=4, fill=shade)
    try:
        font = ImageFont.truetype("arial.ttf", 16)
    except (IOError, OSError):
        font = ImageFont.load_default()
    text = "lc0"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size - tw) // 2, (size - th) // 2 - 3), text, fill="white", font=font)
    return img


# ── Server manager ────────────────────────────────────────────────────────────

class ServerManager:
    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        # Separate from _lock so the enabled-lambda never deadlocks the tray thread
        self._running_flag = threading.Event()

        # Adopt any server already running from a previous launch
        pid = _read_pid()
        if pid and _pid_alive(pid):
            self._external_pid: int | None = pid
            self._running_flag.set()
        else:
            self._external_pid = None
            _clear_pid()

    @property
    def running(self) -> bool:
        """
        Fast, lock-free check used by the menu's enabled lambdas.
        Uses the Event flag which is kept in sync by start() / stop().
        """
        return self._running_flag.is_set()

    def _check_still_alive(self) -> bool:
        """Authoritative check — used inside start/stop where we hold _lock."""
        if self._proc and self._proc.poll() is None:
            return True
        if self._external_pid and _pid_alive(self._external_pid):
            return True
        # Process died unexpectedly — clean up
        self._proc = None
        self._external_pid = None
        self._running_flag.clear()
        _clear_pid()
        return False

    def start(self):
        with self._lock:
            if self._check_still_alive():
                return
            cmd = [
                PYTHON_EXE, str(SERVER_SCRIPT),
                f"--lc0={LC0_EXE}",
                f"--weights={LC0_WEIGHTS}",
                f"--port={LC0_PORT}",
                f"--threads={LC0_THREADS}",
            ]
            self._proc = subprocess.Popen(
                cmd,
                cwd=str(SCRIPT_DIR),
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            _write_pid(self._proc.pid)
            self._running_flag.set()

    def stop(self):
        with self._lock:
            pid_to_kill: int | None = None
            if self._proc and self._proc.poll() is None:
                pid_to_kill = self._proc.pid
                self._proc = None
            elif self._external_pid and _pid_alive(self._external_pid):
                pid_to_kill = self._external_pid
            self._external_pid = None
            self._running_flag.clear()
            _clear_pid()

        # Terminate outside the lock so _pid_alive polling doesn't deadlock
        if pid_to_kill:
            _terminate_pid(pid_to_kill)


# ── Tray callbacks ────────────────────────────────────────────────────────────

manager = ServerManager()

def _refresh(icon: pystray.Icon):
    running = manager.running
    icon.icon  = make_icon(running)
    icon.title = "lc0 — Running" if running else "lc0 — Stopped"

def on_start(icon, item):
    manager.start()
    _refresh(icon)

def on_stop(icon, item):
    manager.stop()
    _refresh(icon)

def on_log(icon, item):
    if LOG_FILE.exists():
        os.startfile(str(LOG_FILE))
    else:
        # Log doesn't exist yet — open the folder so the user can see what's there
        os.startfile(str(SCRIPT_DIR))

def on_quit(icon, item):
    manager.stop()
    icon.stop()


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    icon = pystray.Icon(
        name="lc0",
        icon=make_icon(False),
        title="lc0 — Starting…",
        menu=pystray.Menu(
            pystray.MenuItem("▶  Start", on_start, enabled=lambda i: not manager.running),
            pystray.MenuItem("⏹  Stop",  on_stop,  enabled=lambda i: manager.running),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("📄  Open Log", on_log),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("✕  Quit", on_quit),
        ),
    )
    manager.start()
    _refresh(icon)
    icon.run()


if __name__ == "__main__":
    if "--stop" in sys.argv:
        pid = _read_pid()
        if pid and _pid_alive(pid):
            print(f"Stopping lc0 server (PID {pid})…")
            _terminate_pid(pid)
            _clear_pid()
            print("Stopped.")
        else:
            print("lc0 server is not running.")
            _clear_pid()
        sys.exit(0)

    main()