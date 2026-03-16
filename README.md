# Dacelo — Chess Training App

A chess training app for iOS and macOS that connects to one or more UCI engines
running on a Windows PC over Tailscale. Designed to explain *why* moves are good
or bad, not just whether they are.

---

## What it does

**During play (vs Engine or Two Players)**
- Score, WDL bar, best continuation, move quality badge after every move
- Material balance, piece mobility, game phase
- Position characteristics: type (Equal→Critical), precision required, line type, eval stability
- LLM commentary fires silently in the background as you play

**In Analysis Mode** (enter any time — it's the same as post-game review)
- Everything above, plus:
- Stockfish NNUE term breakdown: Material, Imbalance, Pawns, Mobility, King Safety, Threats, Passed Pawns, Space
- Pawn structure analysis: isolated, doubled, and passed pawns per side with coaching hints
- King safety: attacker count in king zone, castled status, coaching hints
- Per-move AI commentary from a local LLM (Ollama / LM Studio / llama.cpp)
- Move history drawer with full review navigation

---

## Architecture

```
┌─────────────────────────────┐      Tailscale VPN       ┌──────────────────────────────────┐
│      iOS / macOS App        │ ◄── WebSocket (JSON) ──► │        Windows PC                │
│                             │                          │                                  │
│  SwiftUI Views              │                          │  chess_server.py                 │
│  ├── ContentView            │                          │  ├── WebSocket server :8765      │
│  ├── AnalysisPanelViews     │                          │  ├── UCIEngine (one per engine)  │
│  └── MoveHistoryView        │                          │  └── python-chess metrics        │
│                             │                          │                                  │
│  Stores (MainActor)         │                          │  server_tray.py                  │
│  ├── AppStore (root)        │                          │  └── System tray start/stop      │
│  ├── GameStore              │                          │                                  │
│  └── AnalysisStore          │                          │  Engines/                        │
│                             │                          │  ├── lc0.exe + weights.pb        │
│  Services                   │                          │  ├── stockfish.exe               │
│  ├── EngineService (actor)  │                          │  └── any UCI engine              │
│  └── LLMHookService         │                          │                                  │
└─────────────────────────────┘                          └──────────────────────────────────┘
```

### Data flow

1. User plays a move → `GameStore` (via swift-chess `ChessStore`) updates FEN
2. `AnalysisStore` observes the FEN change, enqueues a move analysis task
3. `EngineService.analyse()` sends JSON to `chess_server.py` over WebSocket
4. Server runs the eval engine (Stockfish by default) + optional concurrent NNUE run
5. Response returns score, WDL, alternatives, pawn structure, king safety, characteristics
6. `AnalysisStore` updates all `@Published` state → UI re-renders
7. In analysis mode: `LLMHookService.requestNarrative()` fires concurrently for the move
8. LLM narrative fills into the move's card when it arrives (seconds to minutes later)

If it is the engine's turn (`humanVsEngine` mode), `UCIRobot` calls `EngineService.engineMove()` in parallel — move generation and position analysis are independent.

---

## Windows Setup

### 1. Install Python dependencies

```powershell
pip install websockets python-chess pystray pillow
```

Or with conda:

```powershell
conda create -n dacelo python=3.11
conda activate dacelo
pip install websockets python-chess pystray pillow
```

### 2. Download engines

**Stockfish** (required for full analysis — NNUE terms, calibrated WDL):
- Download from https://stockfishchess.org/download/
- Extract to `Windows/stockfish/stockfish.exe`

**lc0** (optional — for playing against a neural network engine):
- Download from https://github.com/LeelaChessZero/lc0/releases
- Choose `cuda12` for NVIDIA GPU, `cpu-dnnl` for CPU-only
- Extract to `Windows/lc0/lc0.exe`
- Download a weights file from https://lczero.org/play/networks/bestnets/
- Place the `.pb` file next to `lc0.exe`

### 3. Configure `server_tray.py`

Open `server_tray.py` and edit the `ENGINES` list at the top:

```python
ENGINES = [
    (
        "stockfish",
        Path(__file__).parent / r"stockfish\stockfish.exe",
        None,                    # Stockfish needs no weights file
    ),
    (
        "lc0",
        Path(__file__).parent / r"lc0\lc0.exe",
        Path(__file__).parent / r"lc0\BT4-332.pb",
    ),
]

PRIMARY_ENGINE = "lc0"   # Engine used when no specific engine is requested
```

Each tuple is `(name, exe_path, weights_path_or_None)`. The `name` is what you
type in the app's Settings — it can be anything you want.

### 4. Start the server

**Option A — System tray (recommended):**
```powershell
pythonw server_tray.py
```
A tray icon appears. Green = running. Right-click to stop or view logs.

**Option B — Terminal (easier for debugging):**
```powershell
python chess_server.py \
    --engine stockfish=stockfish/stockfish.exe \
    --engine lc0=lc0/lc0.exe:lc0/BT4-332.pb \
    --primary lc0 \
    --port 8765 \
    --threads 4
```

**Option C — Stop a running tray server:**
```powershell
python server_tray.py --stop
```

### 5. Auto-start on Windows login (optional)

Press **Win + R** → type `shell:startup` → drop a shortcut to `server_tray.py` (or a `.bat` that runs it) into that folder.

---

## Adding a New Engine

Dacelo is engine-agnostic. Any UCI-compliant engine works.

### Server side

Add an entry to the `ENGINES` list in `server_tray.py`:

```python
ENGINES = [
    ("stockfish", Path(__file__).parent / r"stockfish\sf17.exe", None),
    ("lc0",       Path(__file__).parent / r"lc0\lc0.exe",        Path(__file__).parent / r"lc0\weights.pb"),
    ("komodo",    Path(__file__).parent / r"komodo\komodo.exe",   None),
    # Add any UCI engine the same way:
    # ("dragon",  Path(__file__).parent / r"dragon\dragon.exe",   None),
]
```

**Engines with weights files** (lc0-style neural networks):
- Pass the weights path as the third element
- The server automatically appends `--weights=<path>` to the launch command

**Engines without weights** (Stockfish, Komodo, etc.):
- Pass `None` as the third element
- The server detects these as "Stockfish-like" and enables `UCI_ShowWDL true` and `Use NNUE true` automatically, enabling the full NNUE breakdown

### App side

1. Restart the server after editing `server_tray.py`
2. In the app's Settings, tap **Refresh Engines** (or disconnect and reconnect)
3. The engine name dropdowns update automatically — select your new engine for:
   - **Move engine**: plays as your opponent
   - **Eval engine**: analyses every position (use Stockfish for NNUE breakdowns)
   - **NNUE engine**: concurrent analysis-mode deep dive (must be Stockfish-compatible)

No code changes required in the Swift app.

### Engine capabilities

| Feature | Stockfish | lc0 | Other UCI |
|---|---|---|---|
| Centipawn score | ✓ | ✓ | ✓ |
| WDL probabilities | ✓ (15.1+) | ✓ | Varies |
| NNUE term breakdown | ✓ | ✗ | ✗ |
| Named eval terms (King Safety, Threats, etc.) | ✓ | ✗ | ✗ |
| MultiPV alternatives | ✓ | ✓ | ✓ |

Recommendation: use **Stockfish as the eval engine** for all analysis. Its WDL is calibrated against real human games, and its NNUE terms let the app explain *why* positions are good or bad. Use lc0 or another engine only as the **move engine** if you want to play against a different style of opponent.

---

## iOS / macOS Xcode Setup

### 1. Create the project

- Xcode → **File → New → Project** → **App**
- Product Name: `Dacelo`, Interface: **SwiftUI**, Language: **Swift**

### 2. Add the swift-chess package

- **Project → Package Dependencies → "+"**
- URL: `https://github.com/dpedley/swift-chess`
- Minimum version: `1.0.8`

### 3. Add source files

Copy all `.swift` files from `Xcode/Dacelo/` into your project. Key groups:

| File | Role |
|---|---|
| `AppStore.swift` | Root coordinator, owns all child stores |
| `AppSettings.swift` | Persisted user preferences |
| `GameStore.swift` | Live chess game state |
| `AnalysisStore.swift` | Move analysis, critiques, LLM contexts |
| `EngineService.swift` | WebSocket client (Swift actor) |
| `EngineModels.swift` | Decodable response types |
| `UCIRobot.swift` | Chess.Player that calls the engine |
| `LLMHookService.swift` | Per-move AI commentary |
| `ContentView.swift` | Main UI + Settings |
| `AnalysisPanelViews.swift` | All analysis panel components |
| `MoveHistoryView.swift` | Move history cards and review UI |
| `MoveHistoryDrawer.swift` | Drag-to-expand bottom drawer |
| `PositionCharacteristics.swift` | Position characteristics model |
| `MoveCritique.swift` | Per-move analysis model |

### 4. Configure network permissions

**macOS** — Signing & Capabilities → App Sandbox → check **Outgoing Connections (Client)**

**iOS** — Info tab, add:

| Key | Value |
|---|---|
| App Transport Security → Allow Arbitrary Loads in Web Content | YES |
| Privacy - Local Network Usage Description | `"Connect to chess engine over Tailscale"` |
| Bonjour services | `_ws._tcp` |

### 5. Build and run

Launch the app, go to **Settings** (gear icon), enter your Windows PC's Tailscale hostname or IP and port, then tap **Connect**. Engine name dropdowns populate automatically from the server.

---

## Settings Reference

| Setting | Default | Description |
|---|---|---|
| Server Host | `your-pc-hostname` | Tailscale hostname or `100.x.x.x` IP |
| Port | `8765` | Must match `--port` on the server |
| Move engine | `lc0` | UCI engine name for opponent moves |
| Move think time | `3000ms` | Time budget per engine move |
| Eval engine | `stockfish` | UCI engine name for position analysis |
| Eval think time | `2000ms` | Time budget per analysis call |
| NNUE engine | `stockfish` | Engine for deep analysis-mode breakdown |
| Show best-move arrow | on | Yellow arrow on the board after each move |
| Hint arrows | 1 | Number of hint arrows shown on request |
| LLM endpoint | `http://localhost:11434` | Ollama / LM Studio / llama.cpp server URL |
| LLM model | `llama3` | Model name as registered in your LLM server |

Engine names must exactly match the `name` field in the server's `ENGINES` list. Tap **Refresh Engines** after changing the server config to re-populate the dropdowns.

---

## WebSocket Protocol Reference

All messages are JSON. Client → Server:

| `cmd` | Additional fields | Description |
|---|---|---|
| `engines` | — | Request list of registered engine names |
| `ping` | — | Keep-alive (server replies `{"type":"pong"}`) |
| `new_game` | — | Reset all engine game state |
| `analyse` | `fen`, `movetime`, `eval_engine`, `best_move_engine`, `nnue_engine`, `deep` | Full position analysis |
| `engine_move` | `fen`, `movetime`, `engine` | Request best move from an engine |

Server → Client (key fields):

| `type` | Key fields |
|---|---|
| `engines` | `engines: [String]`, `primary: String` |
| `analysis` | `score_cp`, `wdl`, `feedback`, `pv`, `alternatives`, `characteristics`, `material_balance`, `mobility_*`, `game_phase`, `nnue`, `pawn_structure`, `isolated_*`, `doubled_*`, `passed_*`, `king_attackers_*`, `king_castled_*`, `deep_score_cp` |
| `engine_move` | `move`, `from`, `to`, `promotion`, `score_cp`, `pv` |
| `error` | `message` |

The `deep` flag on `analyse` enables analysis-mode metrics (pawn structure, king safety) computed via python-chess, and triggers the concurrent NNUE engine run if `nnue_engine` is set.

---

## LLM Commentary Setup

Dacelo supports any Ollama-compatible local LLM server.

**Ollama (simplest):**
```bash
# Install from https://ollama.com
ollama pull llama3        # or mistral, gemma2, phi3, etc.
ollama serve              # starts on localhost:11434
```

**LM Studio:**
- Load any GGUF model, start the local server
- Set endpoint to `http://localhost:1234` in Settings

**llama.cpp server:**
```bash
./server -m model.gguf --port 11434
```

The LLM prompt is automatically enriched with position context: eval score, WDL, game phase, pawn structure, king safety, NNUE term values (if Stockfish ran), and the engine's best continuation. Commentary fires in the background as you play and appears in the move card when you select it in Analysis Mode.

---

## Troubleshooting

**"Not connected" / timeout**
- Confirm Tailscale is running on both devices: `ping <tailscale-ip>` from Mac/iPhone
- Tailscale's `100.x.x.x` addresses bypass the Windows firewall — no inbound rule needed
- Check `chess_server.log` in the Windows folder for UCI handshake errors

**Engine names show as text fields instead of dropdowns**
- The app hasn't connected yet, or the connection was lost
- Tap **Connect** in Settings, then **Refresh Engines**

**lc0 crashes on startup**
- Check your GPU driver; try a CPU-only build (`lc0-…-cpu-dnnl.zip`)

**NNUE breakdown never appears**
- `nnueEngine` in Settings must match a Stockfish-compatible engine name on the server
- NNUE breakdown only appears in Analysis Mode (`deep=true` requests)
- Check the server log for `nnue_engine not found` warnings

**LLM commentary never appears**
- Tap **Apply & Test** in the AI Commentary settings section — the dot should go green
- Ensure the LLM server is running before connecting the chess server
- Commentary only displays in Analysis Mode when a move card is selected

**Conda "command not found" on Windows**
- Open Anaconda Prompt → run `conda init powershell` and `conda init cmd.exe`
- Run PowerShell as Administrator → `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`

---

## Dependencies

| Dependency | License | Purpose |
|---|---|---|
| [swift-chess](https://github.com/dpedley/swift-chess) | MIT | Board, move generation, game state |
| [websockets](https://github.com/aaugustin/websockets) | BSD | Python WebSocket server |
| [python-chess](https://github.com/niklasf/python-chess) | GPL-3 | FEN parsing, pawn/king analysis |
| [pystray](https://github.com/moses-palmer/pystray) | LGPL | Windows system tray |
| [Pillow](https://python-pillow.org) | HPND | Tray icon rendering |
| Stockfish | GPL-3 | Position evaluation, NNUE analysis |
| lc0 | GPL-3 | Neural network chess engine |

This project: MIT