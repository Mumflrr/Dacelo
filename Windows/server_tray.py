"""
server_tray.py — System Tray for the Chess WebSocket Server

Usage:
    pythonw server_tray.py          # start tray (server auto-starts, no console)
    python  server_tray.py --stop   # stop a running server and exit

Requirements:
    pip install pystray pillow

To start on Windows login:
    Win+R → shell:startup → drop a shortcut to server_tray.bat there.
"""

import subprocess, sys, os, threading, time, ctypes
from pathlib import Path
import pystray
from PIL import Image, ImageDraw, ImageFont

# ── Configuration — edit these lines ─────────────────────────────────────────
#
# Add one tuple per engine: (name, exe_path, weights_path_or_None)
#
#   name         — the engine ID used in JSON (e.g. "lc0", "stockfish", "komodo")
#   exe_path     — full path to the UCI binary
#   weights_path — path to a weights/network file, or None if not applicable
#
# The first entry becomes the "primary" engine unless PRIMARY_ENGINE overrides it.

ENGINES = [
    (
        "lc0",
        Path(__file__).parent / r"lc0\lc0.exe",
        Path(__file__).parent / r"lc0\BT4-332.pb",
    ),
    # Uncomment and configure additional engines as needed:
    # (
    #     "stockfish",
    #     Path(__file__).parent / r"stockfish\stockfish.exe",
    #     None,
    # ),
    # (
    #     "komodo",
    #     Path(__file__).parent / r"komodo\komodo.exe",
    #     None,
    # ),
]

SERVER_PORT    = 8765
SERVER_THREADS = 4
PRIMARY_ENGINE = ""   # Leave empty to default to the first ENGINES entry
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "chess_server.py"
LOG_FILE      = SCRIPT_DIR / "chess_server.log"
PID_FILE      = SCRIPT_DIR / "chess_server.pid"
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
    SYNCHRONIZE = 0x00100000
    WAIT_TIMEOUT = 0x00000102
    k32 = ctypes.windll.kernel32
    handle = k32.OpenProcess(SYNCHRONIZE, False, pid)
    if not handle:
        return False
    result = k32.WaitForSingleObject(handle, 0)
    k32.CloseHandle(handle)
    return result == WAIT_TIMEOUT

def _terminate_pid(pid: int, timeout: float = 5.0):
    PROCESS_TERMINATE = 0x0001
    SYNCHRONIZE       = 0x00100000
    WAIT_TIMEOUT_CODE = 0x00000102
    k32 = ctypes.windll.kernel32
    try:
        os.kill(pid, ctypes.c_int(1).value)   # CTRL_BREAK_EVENT
    except (OSError, PermissionError):
        pass
    h = k32.OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE, False, pid)
    if not h:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if k32.WaitForSingleObject(h, 100) != WAIT_TIMEOUT_CODE:
            k32.CloseHandle(h)
            return
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
    text = "UCI"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size - tw) // 2, (size - th) // 2 - 3), text, fill="white", font=font)
    return img


# ── Server manager ────────────────────────────────────────────────────────────

def _build_server_cmd() -> list[str]:
    """
    Build the command list for launching chess_server.py.
    Each engine in ENGINES becomes a --engine NAME=EXE[:WEIGHTS] argument.
    """
    cmd = [
        PYTHON_EXE, str(SERVER_SCRIPT),
        f"--port={SERVER_PORT}",
        f"--threads={SERVER_THREADS}",
    ]
    if PRIMARY_ENGINE:
        cmd.append(f"--primary={PRIMARY_ENGINE}")

    for name, exe, weights in ENGINES:
        spec = f"{name}={exe}"
        if weights:
            spec += f":{weights}"
        cmd.append(f"--engine={spec}")

    return cmd


class ServerManager:
    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._running_flag = threading.Event()

        pid = _read_pid()
        if pid and _pid_alive(pid):
            self._external_pid: int | None = pid
            self._running_flag.set()
        else:
            self._external_pid = None
            _clear_pid()

    @property
    def running(self) -> bool:
        return self._running_flag.is_set()

    def _check_still_alive(self) -> bool:
        if self._proc and self._proc.poll() is None:
            return True
        if self._external_pid and _pid_alive(self._external_pid):
            return True
        self._proc = None
        self._external_pid = None
        self._running_flag.clear()
        _clear_pid()
        return False

    def start(self):
        with self._lock:
            if self._check_still_alive():
                return
            cmd = _build_server_cmd()
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

        if pid_to_kill:
            _terminate_pid(pid_to_kill)


# ── Tray callbacks ────────────────────────────────────────────────────────────

manager = ServerManager()

def _refresh(icon: pystray.Icon):
    running = manager.running
    engine_names = ", ".join(name for name, *_ in ENGINES)
    icon.icon  = make_icon(running)
    icon.title = f"Chess Server ({engine_names}) — {'Running' if running else 'Stopped'}"

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
        os.startfile(str(SCRIPT_DIR))

def on_quit(icon, item):
    manager.stop()
    icon.stop()


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    icon = pystray.Icon(
        name="chess_server",
        icon=make_icon(False),
        title="Chess Server — Starting…",
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
            print(f"Stopping chess server (PID {pid})…")
            _terminate_pid(pid)
            _clear_pid()
            print("Stopped.")
        else:
            print("Chess server is not running.")
            _clear_pid()
        sys.exit(0)

    main()