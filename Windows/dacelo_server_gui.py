"""
dacelo_server_gui.py — Dacelo Server Manager

Lightweight PySide6 GUI for configuring and running chess_server.py.
Replaces server_tray.py and server_tray.bat entirely.

Usage:
    python dacelo_server_gui.py           # launch GUI
    python dacelo_server_gui.py --start   # start server then show UI
    python dacelo_server_gui.py --stop    # stop running server and exit

Requirements:
    pip install PySide6

Config is persisted to dacelo_config.json next to this file.
chess_server.py is unchanged — this GUI just launches it with CLI args.

LLM tab is a placeholder; llama.cpp configuration will be added later.
"""

import sys, os, json, subprocess, threading, time, ctypes
from pathlib import Path

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QLineEdit, QSpinBox, QComboBox,
    QTableWidget, QHeaderView, QFileDialog, QTextEdit, QTabWidget,
    QFrame, QSystemTrayIcon, QMenu, QAbstractItemView, QMessageBox,
    QCheckBox, QSizePolicy,
)
from PySide6.QtCore import Qt, QTimer, QThread, Signal
from PySide6.QtGui import (
    QIcon, QPixmap, QPainter, QColor, QBrush, QFont, QAction, QTextCursor,
)

# ── Paths ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "chess_server.py"
LOG_FILE      = SCRIPT_DIR / "chess_server.log"
PID_FILE      = SCRIPT_DIR / "chess_server.pid"
CONFIG_FILE   = SCRIPT_DIR / "dacelo_config.json"
PYTHON_EXE    = sys.executable

DEFAULT_CONFIG = {
    "engines": [
        {"name": "stockfish", "exe": str(SCRIPT_DIR / "stockfish" / "stockfish.exe"), "weights": "", "enabled": True},
        {"name": "lc0",       "exe": str(SCRIPT_DIR / "lc0" / "lc0.exe"),             "weights": str(SCRIPT_DIR / "lc0" / "BT4-332.pb"), "enabled": True},
    ],
    "primary":          "stockfish",
    "port":             8765,
    "threads":          4,
    "start_minimized":  False,
    "llm":              {"enabled": False, "exe": "", "model": "", "port": 11434, "threads": 4},
}

# ── Config ─────────────────────────────────────────────────────────────────────

def load_config():
    if CONFIG_FILE.exists():
        try:
            data = json.loads(CONFIG_FILE.read_text())
            for k, v in DEFAULT_CONFIG.items():
                if k not in data:
                    data[k] = v
            return data
        except Exception:
            pass
    return json.loads(json.dumps(DEFAULT_CONFIG))

def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))

# ── Windows process helpers ────────────────────────────────────────────────────

def _pid_alive(pid):
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x00100000, False, pid)
    if not h:
        return False
    r = k32.WaitForSingleObject(h, 0)
    k32.CloseHandle(h)
    return r == 0x00000102

def _terminate_pid(pid, timeout=5.0):
    k32 = ctypes.windll.kernel32
    try:
        os.kill(pid, ctypes.c_int(1).value)
    except (OSError, PermissionError):
        pass
    h = k32.OpenProcess(0x00100001, False, pid)
    if not h:
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if k32.WaitForSingleObject(h, 100) != 0x00000102:
            k32.CloseHandle(h)
            return
    k32.TerminateProcess(h, 1)
    k32.CloseHandle(h)

def _read_pid():
    try:
        return int(PID_FILE.read_text().strip())
    except Exception:
        return None

def _clear_pid():
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass

# ── Server manager ─────────────────────────────────────────────────────────────

def build_cmd(cfg):
    cmd = [PYTHON_EXE, str(SERVER_SCRIPT),
           f"--port={cfg['port']}", f"--threads={cfg['threads']}"]
    if cfg.get("primary"):
        cmd.append(f"--primary={cfg['primary']}")
    for e in cfg["engines"]:
        if not e.get("enabled", True) or not e["name"].strip() or not e["exe"].strip():
            continue
        spec = f"{e['name'].strip()}={e['exe'].strip()}"
        if e.get("weights", "").strip():
            spec += f":{e['weights'].strip()}"
        cmd.append(f"--engine={spec}")
    return cmd

class ServerManager:
    def __init__(self):
        self._proc = None
        self._lock = threading.Lock()
        pid = _read_pid()
        self._ext_pid = pid if (pid and _pid_alive(pid)) else None
        if not self._ext_pid:
            _clear_pid()

    @property
    def running(self):
        with self._lock:
            return self._alive()

    def _alive(self):
        if self._proc and self._proc.poll() is None:
            return True
        if self._ext_pid and _pid_alive(self._ext_pid):
            return True
        self._proc = None; self._ext_pid = None; _clear_pid()
        return False

    def start(self, cfg):
        with self._lock:
            if self._alive():
                return False, "Already running."
            enabled = [e for e in cfg["engines"] if e.get("enabled") and e["name"].strip() and e["exe"].strip()]
            if not enabled:
                return False, "No enabled engines configured."
            try:
                self._proc = subprocess.Popen(
                    build_cmd(cfg), cwd=str(SCRIPT_DIR),
                    creationflags=subprocess.CREATE_NO_WINDOW)
                PID_FILE.write_text(str(self._proc.pid))
                return True, f"Started  (PID {self._proc.pid})"
            except Exception as e:
                return False, f"Failed: {e}"

    def stop(self):
        with self._lock:
            kill = None
            if self._proc and self._proc.poll() is None:
                kill = self._proc.pid; self._proc = None
            elif self._ext_pid and _pid_alive(self._ext_pid):
                kill = self._ext_pid
            self._ext_pid = None; _clear_pid()
        if kill:
            _terminate_pid(kill)
            return True, "Stopped."
        return False, "Not running."

# ── Log tailer ─────────────────────────────────────────────────────────────────

class LogTailer(QThread):
    new_lines = Signal(str)
    def __init__(self):
        super().__init__()
        self._stop = threading.Event()
    def run(self):
        last = 0
        while not self._stop.is_set():
            try:
                if LOG_FILE.exists():
                    sz = LOG_FILE.stat().st_size
                    if sz > last:
                        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                            f.seek(last); chunk = f.read()
                        if chunk:
                            self.new_lines.emit(chunk)
                        last = sz
                    elif sz < last:
                        last = 0
            except Exception:
                pass
            time.sleep(0.3)
    def stop_tailer(self):
        self._stop.set()

# ── Tray icon ──────────────────────────────────────────────────────────────────

def make_tray_icon(running):
    pm = QPixmap(64, 64); pm.fill(Qt.transparent)
    p  = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
    p.setBrush(QBrush(QColor("#22C55E" if running else "#505058")))
    p.setPen(Qt.NoPen); p.drawRoundedRect(4, 4, 56, 56, 10, 10)
    p.setPen(QColor("white")); p.setFont(QFont("Arial", 14, QFont.Bold))
    p.drawText(pm.rect(), Qt.AlignCenter, "UCI"); p.end()
    return QIcon(pm)

# ── Dark style ─────────────────────────────────────────────────────────────────

STYLE = """
QMainWindow,QWidget{background:#1a1a1f;color:#e0e0e8;font-family:"Segoe UI",Arial;font-size:13px}
QTabWidget::pane{border:1px solid #2e2e3a;border-radius:6px;background:#1a1a1f}
QTabBar::tab{background:#25252f;color:#888;padding:8px 20px;border-top-left-radius:6px;border-top-right-radius:6px;margin-right:2px}
QTabBar::tab:selected{background:#1a1a1f;color:#e0e0e8;border-bottom:2px solid #7c6af7}
QTabBar::tab:hover{color:#e0e0e8}
QPushButton{background:#2e2e3a;color:#e0e0e8;border:1px solid #3e3e4e;border-radius:6px;padding:6px 16px;min-width:80px}
QPushButton:hover{background:#3a3a4a;border-color:#5a5a7a}
QPushButton:disabled{color:#555;border-color:#2a2a3a}
QPushButton#startBtn{background:#166534;border-color:#15803d;color:#dcfce7;font-weight:bold}
QPushButton#startBtn:hover{background:#15803d}
QPushButton#startBtn:disabled{background:#1a2e20;color:#3a6a45;border-color:#1a2e20}
QPushButton#stopBtn{background:#7f1d1d;border-color:#991b1b;color:#fee2e2;font-weight:bold}
QPushButton#stopBtn:hover{background:#991b1b}
QPushButton#stopBtn:disabled{background:#2e1a1a;color:#6a3a3a;border-color:#2e1a1a}
QPushButton#addBtn{background:#1e3a5f;border-color:#2563eb;color:#bfdbfe}
QPushButton#addBtn:hover{background:#2563eb}
QPushButton#removeBtn{background:#3f1111;border-color:#7f1d1d;color:#fca5a5}
QPushButton#removeBtn:hover{background:#7f1d1d}
QPushButton#upBtn,QPushButton#downBtn{min-width:32px;padding:6px 8px}
QLineEdit,QSpinBox,QComboBox{background:#25252f;border:1px solid #3e3e4e;border-radius:5px;padding:5px 8px;color:#e0e0e8}
QLineEdit:focus,QSpinBox:focus,QComboBox:focus{border-color:#7c6af7}
QComboBox::drop-down{border:none;width:20px}
QComboBox QAbstractItemView{background:#25252f;border:1px solid #3e3e4e;selection-background-color:#4c4c7a}
QSpinBox::up-button,QSpinBox::down-button{background:#3a3a4a;border:none;width:16px}
QTableWidget{background:#1e1e28;alternate-background-color:#22222c;border:1px solid #2e2e3a;border-radius:6px;gridline-color:#2a2a36}
QTableWidget::item{padding:4px 8px}
QTableWidget::item:selected{background:#3a3a5a}
QHeaderView::section{background:#25252f;color:#888;font-size:11px;font-weight:bold;padding:6px 8px;border:none;border-bottom:1px solid #2e2e3a}
QTextEdit{background:#0f0f14;border:1px solid #2e2e3a;border-radius:6px;color:#a0ffa0;font-family:"Consolas","Courier New",monospace;font-size:12px}
QCheckBox{spacing:8px}
QCheckBox::indicator{width:16px;height:16px;border:1px solid #3e3e4e;border-radius:3px;background:#25252f}
QCheckBox::indicator:checked{background:#7c6af7;border-color:#7c6af7}
QFrame#div{background:#2e2e3a;max-height:1px}
QLabel#run{background:#14532d;color:#86efac;font-size:12px;padding:4px 12px;border-radius:10px;font-weight:bold}
QLabel#stop{background:#2d2d35;color:#888;font-size:12px;padding:4px 12px;border-radius:10px;font-weight:bold}
QLabel#sec{color:#7c6af7;font-size:11px;font-weight:bold;letter-spacing:1px}
"""

# ── Engine table widget ────────────────────────────────────────────────────────

class EngineTable(QWidget):
    """
    Editable table: Enabled | Name | Executable | Weights | Browse | Browse
    """
    changed = Signal()
    C_EN=0; C_NM=1; C_EX=2; C_WT=3; C_BE=4; C_BW=5

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self); lay.setContentsMargins(0,0,0,0); lay.setSpacing(8)

        tb = QHBoxLayout()
        self._add = QPushButton("+ Add Engine"); self._add.setObjectName("addBtn")
        self._rem = QPushButton("Remove");       self._rem.setObjectName("removeBtn")
        self._up  = QPushButton("▲");            self._up.setObjectName("upBtn")
        self._dn  = QPushButton("▼");            self._dn.setObjectName("downBtn")
        for w in [self._add, self._rem]: tb.addWidget(w)
        tb.addStretch()
        for w in [self._up, self._dn]:  tb.addWidget(w)
        lay.addLayout(tb)

        self._tbl = QTableWidget(0, 6)
        self._tbl.setHorizontalHeaderLabels(["", "Name", "Executable", "Weights (optional)", "", ""])
        hh = self._tbl.horizontalHeader()
        hh.setSectionResizeMode(self.C_EN, QHeaderView.Fixed)
        hh.setSectionResizeMode(self.C_NM, QHeaderView.ResizeToContents)
        hh.setSectionResizeMode(self.C_EX, QHeaderView.Stretch)
        hh.setSectionResizeMode(self.C_WT, QHeaderView.Stretch)
        hh.setSectionResizeMode(self.C_BE, QHeaderView.Fixed)
        hh.setSectionResizeMode(self.C_BW, QHeaderView.Fixed)
        self._tbl.setColumnWidth(self.C_EN, 36)
        self._tbl.setColumnWidth(self.C_BE, 72)
        self._tbl.setColumnWidth(self.C_BW, 72)
        self._tbl.setAlternatingRowColors(True)
        self._tbl.setSelectionBehavior(QAbstractItemView.SelectRows)
        self._tbl.setSelectionMode(QAbstractItemView.SingleSelection)
        self._tbl.verticalHeader().hide()
        self._tbl.setShowGrid(False)
        lay.addWidget(self._tbl)

        self._add.clicked.connect(lambda: self._append())
        self._rem.clicked.connect(self._remove)
        self._up.clicked.connect(self._move_up)
        self._dn.clicked.connect(self._move_down)

    def load(self, engines):
        self._tbl.setRowCount(0)
        for e in engines:
            self._append(e.get("enabled", True), e.get("name",""), e.get("exe",""), e.get("weights",""))

    def collect(self):
        out = []
        for r in range(self._tbl.rowCount()):
            con  = self._tbl.cellWidget(r, self.C_EN)
            cb   = getattr(con, "_cb", None)
            nm   = self._tbl.cellWidget(r, self.C_NM)
            ex   = self._tbl.cellWidget(r, self.C_EX)
            wt   = self._tbl.cellWidget(r, self.C_WT)
            out.append({
                "enabled": cb.isChecked()       if cb else True,
                "name":    nm.text().strip()     if nm else "",
                "exe":     ex.text().strip()     if ex else "",
                "weights": wt.text().strip()     if wt else "",
            })
        return out

    def names(self):
        return [e["name"] for e in self.collect() if e["enabled"] and e["name"]]

    def _append(self, enabled=True, name="", exe="", weights=""):
        r = self._tbl.rowCount(); self._tbl.insertRow(r)

        cb = QCheckBox(); cb.setChecked(enabled); cb.stateChanged.connect(self.changed)
        con = QWidget(); cl = QHBoxLayout(con)
        cl.addWidget(cb); cl.setAlignment(Qt.AlignCenter); cl.setContentsMargins(0,0,0,0)
        con._cb = cb
        self._tbl.setCellWidget(r, self.C_EN, con)

        nm_e = QLineEdit(name);    nm_e.setPlaceholderText("e.g. stockfish"); nm_e.textChanged.connect(self.changed)
        ex_e = QLineEdit(exe);     ex_e.setPlaceholderText("path\\to\\engine.exe"); ex_e.textChanged.connect(self.changed)
        wt_e = QLineEdit(weights); wt_e.setPlaceholderText("optional — omit for Stockfish"); wt_e.textChanged.connect(self.changed)
        self._tbl.setCellWidget(r, self.C_NM, nm_e)
        self._tbl.setCellWidget(r, self.C_EX, ex_e)
        self._tbl.setCellWidget(r, self.C_WT, wt_e)

        for col, target, filt in [
            (self.C_BE, ex_e, "Executable (*.exe)"),
            (self.C_BW, wt_e, "Weights (*.pb *.pb.gz *.onnx *.bin);;All (*)"),
        ]:
            btn = QPushButton("Browse…"); btn.setFixedWidth(68)
            btn.clicked.connect(lambda _, t=target, f=filt: self._browse(t, f))
            self._tbl.setCellWidget(r, col, btn)

        self._tbl.setRowHeight(r, 38)
        self.changed.emit()

    def _remove(self):
        r = self._tbl.currentRow()
        if r >= 0:
            self._tbl.removeRow(r); self.changed.emit()

    def _move_up(self):
        r = self._tbl.currentRow()
        if r > 0:
            self._swap(r, r-1); self._tbl.selectRow(r-1)

    def _move_down(self):
        r = self._tbl.currentRow()
        if r < self._tbl.rowCount()-1:
            self._swap(r, r+1); self._tbl.selectRow(r+1)

    def _swap(self, a, b):
        def get(r):
            con = self._tbl.cellWidget(r, self.C_EN)
            return {
                "enabled": getattr(con,"_cb",None).isChecked() if con else True,
                "name":    (self._tbl.cellWidget(r,self.C_NM) or QLineEdit()).text(),
                "exe":     (self._tbl.cellWidget(r,self.C_EX) or QLineEdit()).text(),
                "weights": (self._tbl.cellWidget(r,self.C_WT) or QLineEdit()).text(),
            }
        da, db = get(a), get(b)
        lo, hi = min(a,b), max(a,b)
        dl, dh = (db,da) if a<b else (da,db)
        self._tbl.removeRow(hi); self._tbl.removeRow(lo)
        self._tbl.insertRow(lo); self._tbl.insertRow(hi)
        for row, d in [(lo,dl),(hi,dh)]:
            self._append_at(row, d["enabled"], d["name"], d["exe"], d["weights"])
        self.changed.emit()

    def _append_at(self, r, enabled, name, exe, weights):
        cb = QCheckBox(); cb.setChecked(enabled); cb.stateChanged.connect(self.changed)
        con = QWidget(); cl = QHBoxLayout(con)
        cl.addWidget(cb); cl.setAlignment(Qt.AlignCenter); cl.setContentsMargins(0,0,0,0)
        con._cb = cb; self._tbl.setCellWidget(r, self.C_EN, con)
        for col, val, ph in [(self.C_NM,name,"e.g. stockfish"),(self.C_EX,exe,"path\\to\\engine.exe"),(self.C_WT,weights,"optional")]:
            w = QLineEdit(val); w.setPlaceholderText(ph); w.textChanged.connect(self.changed)
            self._tbl.setCellWidget(r, col, w)
        for col, tgt_col, filt in [(self.C_BE,self.C_EX,"Executable (*.exe)"),(self.C_BW,self.C_WT,"Weights (*.pb *.pb.gz *.onnx);;All (*)")]:
            btn = QPushButton("Browse…"); btn.setFixedWidth(68)
            tgt = self._tbl.cellWidget(r, tgt_col)
            btn.clicked.connect(lambda _, t=tgt, f=filt: self._browse(t, f))
            self._tbl.setCellWidget(r, col, btn)
        self._tbl.setRowHeight(r, 38)

    def _browse(self, target, filt):
        path, _ = QFileDialog.getOpenFileName(self, "Select file", str(SCRIPT_DIR), filt)
        if path:
            target.setText(path)

# ── Main window ────────────────────────────────────────────────────────────────

class MainWindow(QMainWindow):
    def __init__(self, mgr):
        super().__init__()
        self._mgr = mgr
        self._cfg = load_config()
        self._tailer = LogTailer()
        self._tailer.new_lines.connect(self._append_log)
        self._tailer.start()

        self.setWindowTitle("Dacelo Server")
        self.setMinimumSize(800, 600)
        self.resize(940, 660)
        self.setStyleSheet(STYLE)
        self._build_ui()
        self._build_tray()
        self._load_ui()
        self._refresh_status()

        self._timer = QTimer(self)
        self._timer.timeout.connect(self._refresh_status)
        self._timer.start(2000)

        if self._cfg.get("start_minimized"):
            self.hide()

    # ── UI ──────────────────────────────────────────────────────────────────

    def _build_ui(self):
        c = QWidget(); self.setCentralWidget(c)
        root = QVBoxLayout(c); root.setContentsMargins(16,16,16,16); root.setSpacing(12)

        # Status bar
        sr = QHBoxLayout()
        self._status_lbl = QLabel("⬤  Stopped"); self._status_lbl.setObjectName("stop")
        self._start_btn  = QPushButton("▶  Start Server"); self._start_btn.setObjectName("startBtn"); self._start_btn.setFixedHeight(36)
        self._stop_btn   = QPushButton("⏹  Stop Server");  self._stop_btn.setObjectName("stopBtn");  self._stop_btn.setFixedHeight(36)
        self._start_btn.clicked.connect(self._do_start)
        self._stop_btn.clicked.connect(self._do_stop)
        sr.addWidget(self._status_lbl); sr.addStretch()
        sr.addWidget(self._start_btn); sr.addWidget(self._stop_btn)
        root.addLayout(sr)

        div = QFrame(); div.setObjectName("div"); div.setFrameShape(QFrame.HLine)
        root.addWidget(div)

        tabs = QTabWidget()
        tabs.addTab(self._tab_engines(), "Engines")
        tabs.addTab(self._tab_server(),  "Server")
        tabs.addTab(self._tab_log(),     "Log")
        tabs.addTab(self._tab_llm(),     "LLM  (coming soon)")
        root.addWidget(tabs)

    def _tab_engines(self):
        w = QWidget(); lay = QVBoxLayout(w); lay.setContentsMargins(12,12,12,12); lay.setSpacing(10)

        hdr = QLabel("UCI ENGINES"); hdr.setObjectName("sec"); lay.addWidget(hdr)

        hint = QLabel(
            "All enabled engines are registered with the server and appear in the iOS/macOS app's engine dropdowns. "
            "Engines without a weights file (e.g. Stockfish) automatically receive UCI_ShowWDL and NNUE eval options."
        )
        hint.setWordWrap(True)
        hint.setStyleSheet("color:#666;font-size:12px;")
        lay.addWidget(hint)

        self._eng_tbl = EngineTable()
        self._eng_tbl.changed.connect(self._on_engines_changed)
        lay.addWidget(self._eng_tbl)

        pr = QHBoxLayout()
        pl = QLabel("Default engine  (used when the app doesn't specify one):"); pl.setStyleSheet("color:#aaa;")
        self._primary = QComboBox(); self._primary.setMinimumWidth(180)
        self._primary.currentTextChanged.connect(self._autosave)
        pr.addWidget(pl); pr.addWidget(self._primary); pr.addStretch()
        lay.addLayout(pr)
        return w

    def _tab_server(self):
        w = QWidget(); lay = QVBoxLayout(w); lay.setContentsMargins(20,20,20,20); lay.setSpacing(16)

        hdr = QLabel("SERVER SETTINGS"); hdr.setObjectName("sec"); lay.addWidget(hdr)

        def row(lbl_text, widget):
            r = QHBoxLayout()
            l = QLabel(lbl_text); l.setFixedWidth(200); l.setStyleSheet("color:#aaa;")
            r.addWidget(l); r.addWidget(widget); r.addStretch()
            return r

        self._port    = QSpinBox(); self._port.setRange(1024,65535);   self._port.setFixedWidth(100);  self._port.valueChanged.connect(self._autosave)
        self._threads = QSpinBox(); self._threads.setRange(1,64);      self._threads.setFixedWidth(100); self._threads.valueChanged.connect(self._autosave)
        lay.addLayout(row("WebSocket port:", self._port))
        lay.addLayout(row("UCI threads per engine:", self._threads))

        self._start_min = QCheckBox("Minimize to tray on launch"); self._start_min.stateChanged.connect(self._autosave)
        lay.addWidget(self._start_min)

        note = QLabel("Changes apply the next time the server is started.")
        note.setStyleSheet("color:#555;font-size:12px;")
        lay.addWidget(note)
        lay.addStretch()
        return w

    def _tab_log(self):
        w = QWidget(); lay = QVBoxLayout(w); lay.setContentsMargins(8,8,8,8); lay.setSpacing(6)
        tb = QHBoxLayout()
        self._autoscroll = QCheckBox("Auto-scroll"); self._autoscroll.setChecked(True)
        clr = QPushButton("Clear"); clr.setFixedWidth(80); clr.clicked.connect(lambda: self._log.clear())
        tb.addWidget(QLabel(f"  {LOG_FILE}")); tb.addStretch()
        tb.addWidget(self._autoscroll); tb.addWidget(clr)
        lay.addLayout(tb)
        self._log = QTextEdit(); self._log.setReadOnly(True); self._log.setLineWrapMode(QTextEdit.NoWrap)
        lay.addWidget(self._log)
        try:
            if LOG_FILE.exists():
                self._log.setPlainText(LOG_FILE.read_text(encoding="utf-8", errors="replace"))
                self._log.verticalScrollBar().setValue(self._log.verticalScrollBar().maximum())
        except Exception:
            pass
        return w

    def _tab_llm(self):
        w = QWidget(); lay = QVBoxLayout(w)
        lay.setContentsMargins(20,60,20,20); lay.setAlignment(Qt.AlignTop)
        icon = QLabel("🤖"); icon.setStyleSheet("font-size:40px;"); icon.setAlignment(Qt.AlignCenter); lay.addWidget(icon)
        title = QLabel("LLM Configuration"); title.setStyleSheet("font-size:18px;font-weight:bold;color:#7c6af7;"); title.setAlignment(Qt.AlignCenter); lay.addWidget(title)
        desc = QLabel("Configure a local LLM (llama.cpp) for AI move commentary.\nThis tab will be enabled in a future update.")
        desc.setAlignment(Qt.AlignCenter); desc.setWordWrap(True); desc.setStyleSheet("color:#666;font-size:13px;")
        lay.addWidget(desc); lay.addStretch()
        return w

    # ── Tray ────────────────────────────────────────────────────────────────

    def _build_tray(self):
        self._tray = QSystemTrayIcon(self)
        self._tray.setIcon(make_tray_icon(False))
        self._tray.setToolTip("Dacelo Server — Stopped")
        m = QMenu()
        for label, fn in [("Show", self._show_win), ("Start Server", self._do_start), ("Stop Server", self._do_stop), (None,None), ("Quit", self._quit)]:
            if label is None:
                m.addSeparator()
            else:
                a = QAction(label, self); a.triggered.connect(fn); m.addAction(a)
        self._tray.setContextMenu(m)
        self._tray.activated.connect(lambda r: self._show_win() if r == QSystemTrayIcon.DoubleClick else None)
        self._tray.show()

    def _show_win(self):
        self.showNormal(); self.activateWindow(); self.raise_()

    # ── Load / save ──────────────────────────────────────────────────────────

    def _load_ui(self):
        self._eng_tbl.load(self._cfg.get("engines", []))
        self._refresh_primary()
        self._primary.setCurrentText(self._cfg.get("primary",""))
        self._port.setValue(self._cfg.get("port", 8765))
        self._threads.setValue(self._cfg.get("threads", 4))
        self._start_min.setChecked(self._cfg.get("start_minimized", False))

    def _collect(self):
        self._cfg["engines"]         = self._eng_tbl.collect()
        self._cfg["primary"]         = self._primary.currentText()
        self._cfg["port"]            = self._port.value()
        self._cfg["threads"]         = self._threads.value()
        self._cfg["start_minimized"] = self._start_min.isChecked()

    def _autosave(self):
        self._collect(); save_config(self._cfg)

    def _refresh_primary(self):
        cur = self._primary.currentText()
        names = self._eng_tbl.names()
        self._primary.blockSignals(True)
        self._primary.clear(); self._primary.addItems(names)
        if cur in names:
            self._primary.setCurrentText(cur)
        elif names:
            self._primary.setCurrentIndex(0)
        self._primary.blockSignals(False)

    def _on_engines_changed(self):
        self._refresh_primary(); self._autosave()

    # ── Server control ────────────────────────────────────────────────────────

    def _do_start(self):
        self._collect(); save_config(self._cfg)
        ok, msg = self._mgr.start(self._cfg)
        if not ok:
            QMessageBox.warning(self, "Dacelo", msg)
        self._refresh_status()

    def _do_stop(self):
        self._mgr.stop(); self._refresh_status()

    def _refresh_status(self):
        running = self._mgr.running
        if running:
            pid = _read_pid()
            self._status_lbl.setText(f"⬤  Running  PID {pid}" if pid else "⬤  Running")
            self._status_lbl.setObjectName("run")
        else:
            self._status_lbl.setText("⬤  Stopped")
            self._status_lbl.setObjectName("stop")
        self._status_lbl.style().unpolish(self._status_lbl)
        self._status_lbl.style().polish(self._status_lbl)
        self._start_btn.setEnabled(not running)
        self._stop_btn.setEnabled(running)
        self._tray.setIcon(make_tray_icon(running))
        self._tray.setToolTip(f"Dacelo Server — {'Running' if running else 'Stopped'}")

    # ── Log ───────────────────────────────────────────────────────────────────

    def _append_log(self, text):
        self._log.moveCursor(QTextCursor.End)
        self._log.insertPlainText(text)
        if self._autoscroll.isChecked():
            self._log.verticalScrollBar().setValue(self._log.verticalScrollBar().maximum())

    # ── Close / quit ──────────────────────────────────────────────────────────

    def closeEvent(self, event):
        event.ignore(); self.hide()
        self._tray.showMessage("Dacelo", "Minimized to tray.", QSystemTrayIcon.Information, 1500)

    def _quit(self):
        if QMessageBox.question(self, "Quit", "Stop the server and quit?",
                                QMessageBox.Yes | QMessageBox.No) == QMessageBox.Yes:
            self._mgr.stop(); self._tailer.stop_tailer(); self._tailer.wait(2000)
            QApplication.quit()

# ── Entry ──────────────────────────────────────────────────────────────────────

def main():
    if "--stop" in sys.argv:
        pid = _read_pid()
        if pid and _pid_alive(pid):
            print(f"Stopping server (PID {pid})…")
            _terminate_pid(pid); _clear_pid(); print("Stopped.")
        else:
            print("Not running."); _clear_pid()
        sys.exit(0)

    app = QApplication(sys.argv)
    app.setApplicationName("Dacelo Server")
    app.setQuitOnLastWindowClosed(False)

    mgr = ServerManager()

    if "--start" in sys.argv:
        mgr.start(load_config())

    win = MainWindow(mgr)
    if "--start" not in sys.argv or not load_config().get("start_minimized"):
        win.show()

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
