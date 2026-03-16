"""
dacelo_server_gui.py — Dacelo Server Manager

PySide6 GUI for configuring and running chess_server.py.
Replaces server_tray.py and server_tray.bat.

Usage:
    python dacelo_server_gui.py           # launch GUI
    python dacelo_server_gui.py --start   # start server then show UI
    python dacelo_server_gui.py --stop    # stop running server and exit

Requirements:
    pip install PySide6

Config persists to dacelo_config.json next to this file.
Engine exe/weights paths use | as the separator (not :) so Windows
drive-letter colons in paths are never misread.
"""

import sys, os, json, subprocess, threading, time, ctypes
from pathlib import Path

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QLineEdit, QSpinBox, QComboBox,
    QTableWidget, QHeaderView, QFileDialog, QTextEdit, QTabWidget,
    QFrame, QSystemTrayIcon, QMenu, QAbstractItemView, QMessageBox,
    QCheckBox, QGraphicsDropShadowEffect, QScrollArea,
)
from PySide6.QtCore import Qt, QTimer, QThread, Signal, QPropertyAnimation, QEasingCurve, QSize
from PySide6.QtGui import (
    QIcon, QPixmap, QPainter, QColor, QBrush, QFont, QAction,
    QTextCursor, QLinearGradient, QPainterPath, QPen,
)

if os.name == 'nt':
    ctypes.windll.user32.ShowWindow(ctypes.windll.kernel32.GetConsoleWindow(), 0)

SCRIPT_DIR    = Path(__file__).parent
SERVER_SCRIPT = SCRIPT_DIR / "chess_server.py"
LOG_FILE      = SCRIPT_DIR / "chess_server.log"
PID_FILE      = SCRIPT_DIR / "chess_server.pid"
CONFIG_FILE   = SCRIPT_DIR / "dacelo_config.json"
PYTHON_EXE    = sys.executable

DEFAULT_CONFIG = {
    "engines": [
        {"name": "stockfish", "exe": str(SCRIPT_DIR/"stockfish"/"stockfish.exe"), "weights": "", "enabled": True},
        {"name": "lc0",       "exe": str(SCRIPT_DIR/"lc0"/"lc0.exe"), "weights": str(SCRIPT_DIR/"lc0"/"BT4-332.pb"), "enabled": True},
    ],
    "primary": "stockfish", "port": 8765, "threads": 4, "start_minimized": False,
    "llm": {"enabled": False, "exe": "", "model": "", "port": 11434, "threads": 4},
}

def load_config():
    if CONFIG_FILE.exists():
        try:
            d = json.loads(CONFIG_FILE.read_text())
            for k, v in DEFAULT_CONFIG.items():
                if k not in d: d[k] = v
            return d
        except Exception: pass
    return json.loads(json.dumps(DEFAULT_CONFIG))

def save_config(cfg): CONFIG_FILE.write_text(json.dumps(cfg, indent=2))

# ── Windows process helpers ────────────────────────────────────────────────────
def _pid_alive(pid):
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x00100000, False, pid)
    if not h: return False
    r = k32.WaitForSingleObject(h, 0); k32.CloseHandle(h)
    return r == 0x00000102

def _terminate_pid(pid, timeout=5.0):
    k32 = ctypes.windll.kernel32
    try: os.kill(pid, ctypes.c_int(1).value)
    except (OSError, PermissionError): pass
    h = k32.OpenProcess(0x00100001, False, pid)
    if not h: return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if k32.WaitForSingleObject(h, 100) != 0x00000102:
            k32.CloseHandle(h); return
    k32.TerminateProcess(h, 1); k32.CloseHandle(h)

def _read_pid():
    try: return int(PID_FILE.read_text().strip())
    except: return None

def _clear_pid():
    try: PID_FILE.unlink(missing_ok=True)
    except: pass

# ── Server manager ─────────────────────────────────────────────────────────────
def build_cmd(cfg):
    cmd = [PYTHON_EXE, str(SERVER_SCRIPT), f"--port={cfg['port']}", f"--threads={cfg['threads']}"]
    if cfg.get("primary"): cmd.append(f"--primary={cfg['primary']}")
    for e in cfg["engines"]:
        if not e.get("enabled", True) or not e["name"].strip() or not e["exe"].strip(): continue
        # Use | as separator so Windows drive-letter colons are not misread
        spec = f"{e['name'].strip()}={e['exe'].strip()}"
        if e.get("weights","").strip(): spec += f"|{e['weights'].strip()}"
        cmd.append(f"--engine={spec}")
    return cmd

class ServerManager:
    def __init__(self):
        self._proc = None; self._lock = threading.Lock()
        pid = _read_pid()
        self._ext = pid if (pid and _pid_alive(pid)) else None
        if not self._ext: _clear_pid()

    @property
    def running(self):
        with self._lock: return self._alive()

    def _alive(self):
        if self._proc and self._proc.poll() is None: return True
        if self._ext and _pid_alive(self._ext): return True
        self._proc = None; self._ext = None; _clear_pid(); return False

    def start(self, cfg):
        with self._lock:
            if self._alive(): return False, "Already running."
            enabled = [e for e in cfg["engines"] if e.get("enabled") and e["name"].strip() and e["exe"].strip()]
            if not enabled: return False, "No enabled engines configured."
            try:
                self._proc = subprocess.Popen(build_cmd(cfg), cwd=str(SCRIPT_DIR),
                                              creationflags=subprocess.CREATE_NO_WINDOW)
                PID_FILE.write_text(str(self._proc.pid))
                return True, f"Started  (PID {self._proc.pid})"
            except Exception as e: return False, f"Failed: {e}"

    def stop(self):
        with self._lock:
            kill = None
            if self._proc and self._proc.poll() is None: kill = self._proc.pid; self._proc = None
            elif self._ext and _pid_alive(self._ext): kill = self._ext
            self._ext = None; _clear_pid()
        if kill: _terminate_pid(kill); return True, "Stopped."
        return False, "Not running."

# ── Log tailer ─────────────────────────────────────────────────────────────────
class LogTailer(QThread):
    new_lines = Signal(str)
    def __init__(self): super().__init__(); self._stop = threading.Event()
    def run(self):
        last = 0
        while not self._stop.is_set():
            try:
                if LOG_FILE.exists():
                    sz = LOG_FILE.stat().st_size
                    if sz > last:
                        with open(LOG_FILE,"r",encoding="utf-8",errors="replace") as f:
                            f.seek(last); chunk=f.read()
                        if chunk: self.new_lines.emit(chunk)
                        last = sz
                    elif sz < last: last = 0
            except: pass
            time.sleep(0.3)
    def stop_tailer(self): self._stop.set()

# ── Tray icon ──────────────────────────────────────────────────────────────────
def make_tray_icon(running):
    pm = QPixmap(64,64); pm.fill(Qt.transparent)
    p = QPainter(pm); p.setRenderHint(QPainter.Antialiasing)
    g = QLinearGradient(0,0,64,64)
    if running:
        g.setColorAt(0, QColor("#22c55e")); g.setColorAt(1, QColor("#16a34a"))
    else:
        g.setColorAt(0, QColor("#3f3f50")); g.setColorAt(1, QColor("#2a2a38"))
    p.setBrush(QBrush(g)); p.setPen(Qt.NoPen)
    p.drawRoundedRect(4,4,56,56,12,12)
    p.setPen(QColor("white")); p.setFont(QFont("Segoe UI",13,QFont.Bold))
    p.drawText(pm.rect(), Qt.AlignCenter, "UCI"); p.end()
    return QIcon(pm)

# ── Style ──────────────────────────────────────────────────────────────────────
# Dark glass aesthetic matching the iOS app: black base, purple accent,
# frosted-glass cards, subtle gradients.
STYLE = """
* { font-family: "Segoe UI", Arial; }

QMainWindow, QDialog { background: #0d0d12; }
QWidget { background: transparent; color: #e0e0ee; font-size: 13px; }

/* ── Tabs ─────────────────────────────────────────────────────────────── */
QTabWidget::pane {
    border: 1px solid rgba(255,255,255,0.07);
    border-radius: 12px;
    background: rgba(255,255,255,0.03);
    margin-top: -1px;
}
QTabBar { background: transparent; }
QTabBar::tab {
    background: transparent;
    color: rgba(255,255,255,0.35);
    padding: 10px 24px;
    border: none;
    font-size: 13px;
    font-weight: 500;
}
QTabBar::tab:selected {
    color: #a78bfa;
    border-bottom: 2px solid #a78bfa;
}
QTabBar::tab:hover { color: rgba(255,255,255,0.7); }

/* ── Buttons ──────────────────────────────────────────────────────────── */
QPushButton {
    background: rgba(255,255,255,0.06);
    color: rgba(255,255,255,0.75);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 8px;
    padding: 7px 18px;
    font-size: 13px;
}
QPushButton:hover {
    background: rgba(255,255,255,0.11);
    border-color: rgba(255,255,255,0.18);
    color: #fff;
}
QPushButton:pressed { background: rgba(255,255,255,0.04); }
QPushButton:disabled { color: rgba(255,255,255,0.2); border-color: rgba(255,255,255,0.05); }

QPushButton#startBtn {
    background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #16a34a, stop:1 #15803d);
    color: #dcfce7; border: none; font-weight: 600; font-size: 14px;
    border-radius: 10px; padding: 9px 24px;
}
QPushButton#startBtn:hover {
    background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #22c55e, stop:1 #16a34a);
}
QPushButton#startBtn:disabled {
    background: rgba(22,163,74,0.2); color: rgba(220,252,231,0.3); border: none;
}
QPushButton#stopBtn {
    background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #dc2626, stop:1 #b91c1c);
    color: #fee2e2; border: none; font-weight: 600; font-size: 14px;
    border-radius: 10px; padding: 9px 24px;
}
QPushButton#stopBtn:hover {
    background: qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 #ef4444, stop:1 #dc2626);
}
QPushButton#stopBtn:disabled {
    background: rgba(220,38,38,0.2); color: rgba(254,226,226,0.3); border: none;
}
QPushButton#addBtn {
    background: rgba(99,102,241,0.15); color: #a5b4fc;
    border: 1px solid rgba(99,102,241,0.35); border-radius: 8px;
}
QPushButton#addBtn:hover { background: rgba(99,102,241,0.28); }
QPushButton#removeBtn {
    background: rgba(220,38,38,0.12); color: #fca5a5;
    border: 1px solid rgba(220,38,38,0.3); border-radius: 8px;
}
QPushButton#removeBtn:hover { background: rgba(220,38,38,0.25); }
QPushButton#upBtn, QPushButton#downBtn {
    min-width: 34px; max-width: 34px; padding: 6px 0;
    font-size: 11px;
}
QPushButton#browseBtn {
    background: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 6px; padding: 4px 8px;
    font-size: 12px; color: rgba(255,255,255,0.5);
    min-width: 60px; max-width: 60px;
}
QPushButton#browseBtn:hover {
    background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.8);
}

/* ── Inputs ───────────────────────────────────────────────────────────── */
QLineEdit, QSpinBox, QComboBox {
    background: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 7px; padding: 6px 10px;
    color: #e0e0ee; font-size: 13px;
    selection-background-color: rgba(167,139,250,0.35);
}
QLineEdit:focus, QSpinBox:focus, QComboBox:focus {
    border-color: rgba(167,139,250,0.6);
    background: rgba(167,139,250,0.07);
}
QLineEdit::placeholder { color: rgba(255,255,255,0.2); }
QComboBox::drop-down { border: none; width: 22px; }
QComboBox::down-arrow { image: none; width: 0; }
QComboBox QAbstractItemView {
    background: #1a1a2e; border: 1px solid rgba(167,139,250,0.3);
    border-radius: 8px; color: #e0e0ee;
    selection-background-color: rgba(167,139,250,0.25);
}
QSpinBox::up-button, QSpinBox::down-button {
    background: rgba(255,255,255,0.06); border: none; width: 18px;
}
QSpinBox::up-button:hover, QSpinBox::down-button:hover {
    background: rgba(255,255,255,0.12);
}

/* ── Table ────────────────────────────────────────────────────────────── */
QTableWidget {
    background: rgba(255,255,255,0.03);
    alternate-background-color: rgba(255,255,255,0.015);
    border: 1px solid rgba(255,255,255,0.07);
    border-radius: 10px; gridline-color: rgba(255,255,255,0.04);
    color: #e0e0ee;
}
QTableWidget::item { padding: 3px 6px; border: none; }
QTableWidget::item:selected {
    background: rgba(167,139,250,0.2); color: #e0e0ee;
}
QHeaderView { background: transparent; }
QHeaderView::section {
    background: rgba(255,255,255,0.04);
    color: rgba(255,255,255,0.35);
    font-size: 10px; font-weight: 600; letter-spacing: 1px;
    text-transform: uppercase; padding: 7px 8px;
    border: none; border-bottom: 1px solid rgba(255,255,255,0.07);
}

/* ── Log view ─────────────────────────────────────────────────────────── */
QTextEdit {
    background: #080810; border: 1px solid rgba(255,255,255,0.07);
    border-radius: 10px; color: #6ee7b7;
    font-family: "Cascadia Code","Consolas","Courier New",monospace;
    font-size: 12px; selection-background-color: rgba(110,231,183,0.2);
}

/* ── Checkbox ─────────────────────────────────────────────────────────── */
QCheckBox { spacing: 8px; color: rgba(255,255,255,0.7); }
QCheckBox::indicator {
    width: 17px; height: 17px;
    border: 1.5px solid rgba(255,255,255,0.2);
    border-radius: 4px; background: rgba(255,255,255,0.04);
}
QCheckBox::indicator:checked {
    background: #7c3aed; border-color: #a78bfa;
}
QCheckBox::indicator:hover { border-color: rgba(167,139,250,0.5); }

/* ── Scrollbar ────────────────────────────────────────────────────────── */
QScrollBar:vertical {
    background: transparent; width: 6px; margin: 0;
}
QScrollBar::handle:vertical {
    background: rgba(255,255,255,0.15); border-radius: 3px; min-height: 30px;
}
QScrollBar::handle:vertical:hover { background: rgba(255,255,255,0.28); }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar:horizontal {
    background: transparent; height: 6px;
}
QScrollBar::handle:horizontal {
    background: rgba(255,255,255,0.15); border-radius: 3px;
}

/* ── Named labels ─────────────────────────────────────────────────────── */
QLabel#statusRun {
    color: #4ade80; font-size: 13px; font-weight: 600;
    padding: 5px 14px; border-radius: 20px;
    background: rgba(74,222,128,0.12);
    border: 1px solid rgba(74,222,128,0.25);
}
QLabel#statusStop {
    color: rgba(255,255,255,0.3); font-size: 13px; font-weight: 600;
    padding: 5px 14px; border-radius: 20px;
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08);
}
QLabel#appTitle {
    color: #fff; font-size: 20px; font-weight: 700; letter-spacing: 0.5px;
}
QLabel#appSubtitle {
    color: rgba(255,255,255,0.3); font-size: 12px;
}
QLabel#sectionHdr {
    color: rgba(167,139,250,0.8); font-size: 10px;
    font-weight: 700; letter-spacing: 2px;
}
QLabel#hint {
    color: rgba(255,255,255,0.28); font-size: 12px;
    line-height: 1.5;
}
QLabel#fieldLbl {
    color: rgba(255,255,255,0.45); font-size: 12px;
}

/* ── Card frame ───────────────────────────────────────────────────────── */
QFrame#card {
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 14px;
}
QFrame#div {
    background: rgba(255,255,255,0.07); max-height: 1px;
}
"""


# ── Glass card widget ──────────────────────────────────────────────────────────
class Card(QFrame):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("card")

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = self.rect().adjusted(0,0,-1,-1)
        path = QPainterPath()
        path.addRoundedRect(r.x(), r.y(), r.width(), r.height(), 14, 14)
        p.fillPath(path, QColor(255,255,255,10))
        pen = QPen(QColor(255,255,255,20), 1)
        p.setPen(pen); p.drawPath(path)
        p.end()


# ── Engine table ──────────────────────────────────────────────────────────────
class EngineTable(QWidget):
    changed = Signal()
    # 4 columns: Enabled | Name | Executable (+ Browse) | Weights (+ Browse)
    C_EN=0; C_NM=1; C_EX=2; C_WT=3

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self); lay.setContentsMargins(0,0,0,0); lay.setSpacing(10)

        tb = QHBoxLayout(); tb.setSpacing(8)
        self._add = QPushButton("+ Add Engine"); self._add.setObjectName("addBtn"); self._add.setFixedHeight(32)
        self._rem = QPushButton("Remove");       self._rem.setObjectName("removeBtn"); self._rem.setFixedHeight(32)
        self._up  = QPushButton("↑");            self._up.setObjectName("upBtn");  self._up.setFixedHeight(32)
        self._dn  = QPushButton("↓");            self._dn.setObjectName("downBtn"); self._dn.setFixedHeight(32)
        for w in [self._add, self._rem]: tb.addWidget(w)
        tb.addStretch()
        for w in [self._up, self._dn]: tb.addWidget(w)
        lay.addLayout(tb)

        self._tbl = QTableWidget(0, 4)
        self._tbl.setHorizontalHeaderLabels(["", "Name", "Executable", "Weights  (optional — omit for Stockfish)"])
        hh = self._tbl.horizontalHeader()
        hh.setSectionResizeMode(self.C_EN, QHeaderView.Fixed)
        hh.setSectionResizeMode(self.C_NM, QHeaderView.ResizeToContents)
        hh.setSectionResizeMode(self.C_EX, QHeaderView.Stretch)
        hh.setSectionResizeMode(self.C_WT, QHeaderView.Stretch)
        self._tbl.setColumnWidth(self.C_EN, 36)
        self._tbl.setAlternatingRowColors(True)
        self._tbl.setSelectionBehavior(QAbstractItemView.SelectRows)
        self._tbl.setSelectionMode(QAbstractItemView.SingleSelection)
        self._tbl.verticalHeader().hide()
        self._tbl.setShowGrid(False)
        self._tbl.setFocusPolicy(Qt.NoFocus)
        lay.addWidget(self._tbl)

        self._add.clicked.connect(lambda: self._append())
        self._rem.clicked.connect(self._remove)
        self._up.clicked.connect(self._move_up)
        self._dn.clicked.connect(self._move_down)

    def load(self, engines):
        self._tbl.setRowCount(0)
        for e in engines:
            self._append(e.get("enabled",True), e.get("name",""), e.get("exe",""), e.get("weights",""))

    def collect(self):
        out = []
        for r in range(self._tbl.rowCount()):
            con  = self._tbl.cellWidget(r, self.C_EN)
            cb   = getattr(con, "_cb", None)
            nm   = self._tbl.cellWidget(r, self.C_NM)
            ex_w = self._tbl.cellWidget(r, self.C_EX)  # QWidget containing QLineEdit + QPushButton
            wt_w = self._tbl.cellWidget(r, self.C_WT)
            ex   = getattr(ex_w, "_edit", None)
            wt   = getattr(wt_w, "_edit", None)
            out.append({
                "enabled": cb.isChecked()      if cb else True,
                "name":    nm.text().strip()    if nm else "",
                "exe":     ex.text().strip()    if ex else "",
                "weights": wt.text().strip()    if wt else "",
            })
        return out

    def names(self):
        return [e["name"] for e in self.collect() if e["enabled"] and e["name"]]

    def _make_input(self, val, ph):
        w = QLineEdit(val); w.setPlaceholderText(ph)
        w.textChanged.connect(self.changed)
        return w

    def _make_field_cell(self, val, ph, filt):
        """QWidget containing a QLineEdit + inline Browse button, used as a table cell."""
        w = QWidget(); lay = QHBoxLayout(w); lay.setContentsMargins(4,2,4,2); lay.setSpacing(4)
        edit = QLineEdit(val); edit.setPlaceholderText(ph); edit.textChanged.connect(self.changed)
        btn = QPushButton("Browse"); btn.setObjectName("browseBtn"); btn.setFixedWidth(60); btn.setFixedHeight(26)
        btn.clicked.connect(lambda _, e=edit, f=filt: self._browse(e, f))
        lay.addWidget(edit); lay.addWidget(btn)
        w._edit = edit  # expose for collect()
        return w

    def _append(self, enabled=True, name="", exe="", weights=""):
        r = self._tbl.rowCount(); self._tbl.insertRow(r)
        cb = QCheckBox(); cb.setChecked(enabled); cb.stateChanged.connect(self.changed)
        con = QWidget(); cl = QHBoxLayout(con)
        cl.addWidget(cb); cl.setAlignment(Qt.AlignCenter); cl.setContentsMargins(0,0,0,0)
        con._cb = cb; self._tbl.setCellWidget(r, self.C_EN, con)
        nm_e = self._make_input(name, "e.g. stockfish")
        self._tbl.setCellWidget(r, self.C_NM, nm_e)
        self._tbl.setCellWidget(r, self.C_EX, self._make_field_cell(exe,     r"path\to\engine.exe",          "Executable (*.exe)"))
        self._tbl.setCellWidget(r, self.C_WT, self._make_field_cell(weights, r"path\to\weights.pb  (blank for Stockfish)", "Weights (*.pb *.pb.gz *.onnx *.bin);;All (*)"))
        self._tbl.setRowHeight(r, 40)
        self.changed.emit()

    def _remove(self):
        r = self._tbl.currentRow()
        if r >= 0: self._tbl.removeRow(r); self.changed.emit()

    def _move_up(self):
        r = self._tbl.currentRow()
        if r > 0: self._swap(r, r-1); self._tbl.selectRow(r-1)

    def _move_down(self):
        r = self._tbl.currentRow()
        if r < self._tbl.rowCount()-1: self._swap(r, r+1); self._tbl.selectRow(r+1)

    def _swap(self, a, b):
        def get(r):
            con  = self._tbl.cellWidget(r, self.C_EN)
            ex_w = self._tbl.cellWidget(r, self.C_EX)
            wt_w = self._tbl.cellWidget(r, self.C_WT)
            nm   = self._tbl.cellWidget(r, self.C_NM)
            return {"enabled": getattr(con,"_cb",None).isChecked() if con else True,
                    "name": nm.text() if nm else "",
                    "exe":  getattr(ex_w,"_edit",QLineEdit()).text() if ex_w else "",
                    "weights": getattr(wt_w,"_edit",QLineEdit()).text() if wt_w else ""}
        da, db = get(a), get(b)
        lo, hi = min(a,b), max(a,b)
        dl, dh = (db,da) if a<b else (da,db)
        self._tbl.removeRow(hi); self._tbl.removeRow(lo)
        self._tbl.insertRow(lo); self._tbl.insertRow(hi)
        for row, d in [(lo,dl),(hi,dh)]: self._fill(row, d["enabled"], d["name"], d["exe"], d["weights"])
        self.changed.emit()

    def _fill(self, r, enabled, name, exe, weights):
        cb = QCheckBox(); cb.setChecked(enabled); cb.stateChanged.connect(self.changed)
        con = QWidget(); cl = QHBoxLayout(con)
        cl.addWidget(cb); cl.setAlignment(Qt.AlignCenter); cl.setContentsMargins(0,0,0,0)
        con._cb = cb; self._tbl.setCellWidget(r, self.C_EN, con)
        nm_e = self._make_input(name, "e.g. stockfish")
        self._tbl.setCellWidget(r, self.C_NM, nm_e)
        self._tbl.setCellWidget(r, self.C_EX, self._make_field_cell(exe,     r"path\to\engine.exe",   "Executable (*.exe)"))
        self._tbl.setCellWidget(r, self.C_WT, self._make_field_cell(weights, r"path\to\weights.pb", "Weights (*.pb *.pb.gz *.onnx);;All (*)"))
        self._tbl.setRowHeight(r, 40)

    def _browse(self, target, filt):
        path, _ = QFileDialog.getOpenFileName(self, "Select file", str(SCRIPT_DIR), filt)
        if path: target.setText(path)


# ── Header bar (gradient like ContentView) ────────────────────────────────────
class HeaderBar(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(72)

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        g = QLinearGradient(0,0,self.width(),self.height())
        g.setColorAt(0.0,  QColor(0,0,0,255))
        g.setColorAt(0.45, QColor(29,7,82,180))
        g.setColorAt(0.85, QColor(59,7,100,140))
        g.setColorAt(1.0,  QColor(0,0,0,230))
        p.fillRect(self.rect(), g)
        p.end()


# ── Main window ────────────────────────────────────────────────────────────────
class MainWindow(QMainWindow):
    def __init__(self, mgr):
        super().__init__()
        self._mgr = mgr
        self._cfg = load_config()
        self._tailer = LogTailer()
        self._tailer.new_lines.connect(self._append_log)
        self._tailer.start()
        self.setWindowTitle("Dacelo")
        self.setMinimumSize(840, 620)
        self.resize(980, 700)
        self.setStyleSheet(STYLE)

        # True-black background painted on the central widget
        bg = QWidget(); bg.setStyleSheet("background:#0a0a0f;")
        self.setCentralWidget(bg)
        root = QVBoxLayout(bg); root.setContentsMargins(0,0,0,0); root.setSpacing(0)

        root.addWidget(self._build_header())

        body = QWidget(); body.setStyleSheet("background:transparent;")
        body_lay = QVBoxLayout(body); body_lay.setContentsMargins(20,16,20,20); body_lay.setSpacing(14)
        body_lay.addWidget(self._build_status_bar())
        body_lay.addWidget(self._build_tabs(), 1)
        root.addWidget(body, 1)

        self._build_tray()
        self._load_ui()
        self._refresh_status()
        self._timer = QTimer(self); self._timer.timeout.connect(self._refresh_status); self._timer.start(2000)
        if self._cfg.get("start_minimized"): self.hide()

    # ── Header ──────────────────────────────────────────────────────────────
    def _build_header(self):
        bar = HeaderBar()
        lay = QHBoxLayout(bar); lay.setContentsMargins(24,0,24,0)
        icon_lbl = QLabel("♟"); icon_lbl.setStyleSheet("font-size:28px; color:rgba(167,139,250,0.9); background:transparent;")
        title = QLabel("Dacelo Server"); title.setObjectName("appTitle"); title.setStyleSheet("background:transparent; color:#fff; font-size:20px; font-weight:700;")
        sub   = QLabel("UCI Engine Manager"); sub.setObjectName("appSubtitle"); sub.setStyleSheet("background:transparent; color:rgba(255,255,255,0.3); font-size:12px;")
        vt = QVBoxLayout(); vt.setSpacing(1); vt.addWidget(title); vt.addWidget(sub)
        lay.addWidget(icon_lbl); lay.addSpacing(10); lay.addLayout(vt); lay.addStretch()
        return bar

    # ── Status bar ───────────────────────────────────────────────────────────
    def _build_status_bar(self):
        w = QWidget(); w.setStyleSheet("background:transparent;")
        lay = QHBoxLayout(w); lay.setContentsMargins(0,0,0,0); lay.setSpacing(10)
        self._status_lbl = QLabel("● Stopped"); self._status_lbl.setObjectName("statusStop")
        self._start_btn = QPushButton("▶  Start Server"); self._start_btn.setObjectName("startBtn"); self._start_btn.setFixedHeight(40); self._start_btn.setMinimumWidth(160)
        self._stop_btn  = QPushButton("■  Stop Server");  self._stop_btn.setObjectName("stopBtn");  self._stop_btn.setFixedHeight(40);  self._stop_btn.setMinimumWidth(160)
        self._start_btn.clicked.connect(self._do_start)
        self._stop_btn.clicked.connect(self._do_stop)
        lay.addWidget(self._status_lbl); lay.addStretch()
        lay.addWidget(self._start_btn); lay.addWidget(self._stop_btn)
        return w

    # ── Tabs ─────────────────────────────────────────────────────────────────
    def _build_tabs(self):
        tabs = QTabWidget()
        tabs.setStyleSheet("QTabWidget{background:transparent;} QTabWidget::pane{margin-top:0;}")
        tabs.addTab(self._tab_engines(), "  Engines  ")
        tabs.addTab(self._tab_server(),  "  Server   ")
        tabs.addTab(self._tab_log(),     "  Log      ")
        tabs.addTab(self._tab_llm(),     "  LLM      ")
        return tabs

    # ── Engines tab ──────────────────────────────────────────────────────────
    def _tab_engines(self):
        w = QWidget(); w.setStyleSheet("background:transparent;")
        lay = QVBoxLayout(w); lay.setContentsMargins(16,16,16,16); lay.setSpacing(12)

        hdr = QLabel("UCI ENGINES"); hdr.setObjectName("sectionHdr")
        hint = QLabel(
            "All enabled engines are registered with the server and appear in the iOS/macOS "
            "app's engine dropdowns.  Engines without a weights file (e.g. Stockfish) "
            "automatically receive UCI_ShowWDL and NNUE eval — required for full analysis."
        )
        hint.setObjectName("hint"); hint.setWordWrap(True); hint.setStyleSheet("background:transparent; color:rgba(255,255,255,0.28); font-size:12px;")
        lay.addWidget(hdr); lay.addWidget(hint)

        self._eng_tbl = EngineTable()
        self._eng_tbl.changed.connect(self._on_engines_changed)
        lay.addWidget(self._eng_tbl, 1)

        # Primary selector row
        pr_card = Card(); pr_lay = QHBoxLayout(pr_card); pr_lay.setContentsMargins(16,12,16,12)
        lbl = QLabel("Default engine"); lbl.setObjectName("fieldLbl"); lbl.setStyleSheet("color:rgba(255,255,255,0.45); background:transparent;")
        sub = QLabel("Used when the app doesn't request a specific engine"); sub.setStyleSheet("color:rgba(255,255,255,0.22); font-size:11px; background:transparent;")
        txt = QVBoxLayout(); txt.setSpacing(1); txt.addWidget(lbl); txt.addWidget(sub)
        self._primary = QComboBox(); self._primary.setMinimumWidth(200); self._primary.setFixedHeight(36)
        self._primary.currentTextChanged.connect(self._autosave)
        pr_lay.addLayout(txt); pr_lay.addStretch(); pr_lay.addWidget(self._primary)
        lay.addWidget(pr_card)
        return w

    # ── Server tab ───────────────────────────────────────────────────────────
    def _tab_server(self):
        w = QWidget(); w.setStyleSheet("background:transparent;")
        lay = QVBoxLayout(w); lay.setContentsMargins(16,16,16,16); lay.setSpacing(12)

        hdr = QLabel("SERVER SETTINGS"); hdr.setObjectName("sectionHdr"); lay.addWidget(hdr)

        card = Card(); cl = QVBoxLayout(card); cl.setContentsMargins(20,16,20,16); cl.setSpacing(16)

        def field_row(label, sublabel, widget):
            r = QHBoxLayout(); r.setSpacing(16)
            labels = QVBoxLayout(); labels.setSpacing(2)
            lbl = QLabel(label); lbl.setStyleSheet("color:rgba(255,255,255,0.75); background:transparent;")
            sub = QLabel(sublabel); sub.setStyleSheet("color:rgba(255,255,255,0.28); font-size:11px; background:transparent;")
            labels.addWidget(lbl); labels.addWidget(sub)
            r.addLayout(labels); r.addStretch(); r.addWidget(widget)
            return r

        self._port = QSpinBox(); self._port.setRange(1024,65535); self._port.setFixedWidth(110); self._port.setFixedHeight(36); self._port.valueChanged.connect(self._autosave)
        self._threads = QSpinBox(); self._threads.setRange(1,64); self._threads.setFixedWidth(110); self._threads.setFixedHeight(36); self._threads.valueChanged.connect(self._autosave)

        cl.addLayout(field_row("WebSocket port", "iOS/macOS app must match this value", self._port))
        div = QFrame(); div.setObjectName("div"); div.setFrameShape(QFrame.HLine); cl.addWidget(div)
        cl.addLayout(field_row("UCI threads per engine", "Higher = faster analysis, more CPU", self._threads))
        div2 = QFrame(); div2.setObjectName("div"); div2.setFrameShape(QFrame.HLine); cl.addWidget(div2)

        self._start_min = QCheckBox("Minimize to tray on launch"); self._start_min.stateChanged.connect(self._autosave)
        cl.addWidget(self._start_min)
        lay.addWidget(card); lay.addStretch()
        return w

    # ── Log tab ──────────────────────────────────────────────────────────────
    def _tab_log(self):
        w = QWidget(); w.setStyleSheet("background:transparent;")
        lay = QVBoxLayout(w); lay.setContentsMargins(16,16,16,16); lay.setSpacing(10)

        tb = QHBoxLayout()
        path_lbl = QLabel(str(LOG_FILE)); path_lbl.setStyleSheet("color:rgba(255,255,255,0.2); font-size:11px; background:transparent;")
        self._autoscroll = QCheckBox("Auto-scroll"); self._autoscroll.setChecked(True)
        clr = QPushButton("Clear log"); clr.setFixedWidth(90); clr.setFixedHeight(30); clr.clicked.connect(lambda: self._log.clear())
        tb.addWidget(path_lbl); tb.addStretch(); tb.addWidget(self._autoscroll); tb.addSpacing(8); tb.addWidget(clr)
        lay.addLayout(tb)

        self._log = QTextEdit(); self._log.setReadOnly(True); self._log.setLineWrapMode(QTextEdit.NoWrap)
        lay.addWidget(self._log, 1)
        try:
            if LOG_FILE.exists():
                self._log.setPlainText(LOG_FILE.read_text(encoding="utf-8", errors="replace"))
                self._log.verticalScrollBar().setValue(self._log.verticalScrollBar().maximum())
        except: pass
        return w

    # ── LLM tab (placeholder) ────────────────────────────────────────────────
    def _tab_llm(self):
        w = QWidget(); w.setStyleSheet("background:transparent;")
        lay = QVBoxLayout(w); lay.setContentsMargins(16,40,16,16); lay.setSpacing(12); lay.setAlignment(Qt.AlignTop | Qt.AlignHCenter)

        card = Card(); card.setFixedWidth(420)
        cl = QVBoxLayout(card); cl.setContentsMargins(32,32,32,32); cl.setSpacing(14); cl.setAlignment(Qt.AlignCenter)

        icon = QLabel("🤖"); icon.setStyleSheet("font-size:44px; background:transparent;"); icon.setAlignment(Qt.AlignCenter)
        title = QLabel("LLM Configuration")
        title.setStyleSheet("font-size:17px; font-weight:700; color:#a78bfa; background:transparent;"); title.setAlignment(Qt.AlignCenter)
        desc = QLabel("Configure a local LLM (llama.cpp) for\nAI move commentary in Analysis Mode.\n\nThis tab will be enabled in a future update.")
        desc.setStyleSheet("color:rgba(255,255,255,0.35); font-size:13px; background:transparent;")
        desc.setAlignment(Qt.AlignCenter); desc.setWordWrap(True)

        badge = QLabel("Coming soon")
        badge.setStyleSheet("color:rgba(167,139,250,0.7); font-size:11px; font-weight:600; background:rgba(124,58,237,0.15); border:1px solid rgba(124,58,237,0.3); border-radius:10px; padding:3px 12px;")
        badge.setAlignment(Qt.AlignCenter)

        for lw in [icon, title, desc, badge]: cl.addWidget(lw)
        lay.addWidget(card, alignment=Qt.AlignHCenter)
        return w

    # ── Tray ─────────────────────────────────────────────────────────────────
    def _build_tray(self):
        self._tray = QSystemTrayIcon(self)
        self._tray.setIcon(make_tray_icon(False))
        m = QMenu()
        for label, fn in [("Show", self._show_win),("Start Server",self._do_start),
                          ("Stop Server",self._do_stop),(None,None),("Quit",self._quit)]:
            if label is None: m.addSeparator()
            else:
                a = QAction(label,self); a.triggered.connect(fn); m.addAction(a)
        self._tray.setContextMenu(m)
        self._tray.activated.connect(lambda r: self._show_win() if r==QSystemTrayIcon.DoubleClick else None)
        self._tray.show()

    def _show_win(self): self.showNormal(); self.activateWindow(); self.raise_()

    # ── Load / save ──────────────────────────────────────────────────────────
    def _load_ui(self):
        self._eng_tbl.load(self._cfg.get("engines",[]))
        self._refresh_primary()
        self._primary.setCurrentText(self._cfg.get("primary",""))
        self._port.setValue(self._cfg.get("port",8765))
        self._threads.setValue(self._cfg.get("threads",4))
        self._start_min.setChecked(self._cfg.get("start_minimized",False))

    def _collect(self):
        self._cfg["engines"]        = self._eng_tbl.collect()
        self._cfg["primary"]        = self._primary.currentText()
        self._cfg["port"]           = self._port.value()
        self._cfg["threads"]        = self._threads.value()
        self._cfg["start_minimized"]= self._start_min.isChecked()

    def _autosave(self): self._collect(); save_config(self._cfg)

    def _refresh_primary(self):
        cur = self._primary.currentText(); names = self._eng_tbl.names()
        self._primary.blockSignals(True); self._primary.clear(); self._primary.addItems(names)
        if cur in names: self._primary.setCurrentText(cur)
        elif names: self._primary.setCurrentIndex(0)
        self._primary.blockSignals(False)

    def _on_engines_changed(self): self._refresh_primary(); self._autosave()

    # ── Server control ────────────────────────────────────────────────────────
    def _do_start(self):
        self._collect(); save_config(self._cfg)
        ok, msg = self._mgr.start(self._cfg)
        if not ok: QMessageBox.warning(self, "Dacelo", msg)
        self._refresh_status()

    def _do_stop(self): self._mgr.stop(); self._refresh_status()

    def _refresh_status(self):
        running = self._mgr.running
        if running:
            pid = _read_pid()
            self._status_lbl.setText(f"● Running  —  PID {pid}" if pid else "● Running")
            self._status_lbl.setObjectName("statusRun")
        else:
            self._status_lbl.setText("● Stopped")
            self._status_lbl.setObjectName("statusStop")
        self._status_lbl.style().unpolish(self._status_lbl)
        self._status_lbl.style().polish(self._status_lbl)
        self._start_btn.setEnabled(not running)
        self._stop_btn.setEnabled(running)
        self._tray.setIcon(make_tray_icon(running))
        self._tray.setToolTip(f"Dacelo — {'Running' if running else 'Stopped'}")

    # ── Log ───────────────────────────────────────────────────────────────────
    def _append_log(self, text):
        self._log.moveCursor(QTextCursor.End); self._log.insertPlainText(text)
        if self._autoscroll.isChecked():
            self._log.verticalScrollBar().setValue(self._log.verticalScrollBar().maximum())

    # ── Close ─────────────────────────────────────────────────────────────────
    def closeEvent(self, event):
        event.ignore(); self.hide()
        self._tray.showMessage("Dacelo","Minimized to tray.",QSystemTrayIcon.Information,1500)

    def _quit(self):
        if QMessageBox.question(self,"Quit","Stop the server and quit?",
                                QMessageBox.Yes|QMessageBox.No) == QMessageBox.Yes:
            self._mgr.stop(); self._tailer.stop_tailer(); self._tailer.wait(2000)
            QApplication.quit()


# ── Entry ──────────────────────────────────────────────────────────────────────
def main():
    if "--stop" in sys.argv:
        pid = _read_pid()
        if pid and _pid_alive(pid):
            print(f"Stopping (PID {pid})…"); _terminate_pid(pid); _clear_pid(); print("Done.")
        else:
            print("Not running."); _clear_pid()
        sys.exit(0)

    app = QApplication(sys.argv)
    app.setApplicationName("Dacelo")
    app.setQuitOnLastWindowClosed(False)

    mgr = ServerManager()
    if "--start" in sys.argv: mgr.start(load_config())

    win = MainWindow(mgr)
    if "--start" not in sys.argv or not load_config().get("start_minimized"):
        win.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()