# LeelaChessApp — iOS/macOS ↔ Windows PC via Tailscale

A chess app where your Apple devices use **Leela Chess Zero (lc0)** running on your Windows PC
as the AI engine. Communication happens over your **Tailscale** private network.

---

## Architecture Overview

```
┌─────────────────────────────┐        Tailscale VPN        ┌──────────────────────────────┐
│      iOS / macOS App        │  ◄── WebSocket (JSON) ──►   │        Windows PC             │
│                             │                              │                               │
│  SwiftUI BoardView          │                              │  lc0_server.py                │
│  (swift-chess package)      │                              │   ├── WebSocket server :8765  │
│                             │                              │   └── lc0.exe (UCI pipe)      │
│  ChessStore (Combine)       │                              │                               │
│  AppStore (ObservableObj)   │                              │  lc0_tray.py                  │
│  NetworkService (WebSocket) │                              │   └── System tray on/off      │
│  Lc0Player (custom player)  │                              │                               │
│  AnalysisService            │                              │  lc0.exe + weights .pb.gz     │
└─────────────────────────────┘                              └──────────────────────────────┘
```

### Data Flow

1. User taps a move on the board → swift-chess `ChessStore` updates game state
2. If it's the engine's turn → `Lc0Player.move()` fires
3. `NetworkService.engineMove(fen:)` sends JSON over WebSocket to PC
4. `lc0_server.py` pipes `position fen … go movetime …` to `lc0.exe`
5. lc0 replies with `bestmove e2e4`; server sends JSON back
6. `Lc0Player` calls `store.send(.make(move:))` to play the move
7. After every move, `AnalysisService.analyse(fen:)` fetches feedback

---

## Project Structure

```
LeelaChessApp/
│
├── Windows/                        ← Run on your PC
│   ├── lc0_server.py               ← WebSocket server wrapping lc0 UCI
│   ├── lc0_tray.py                 ← System tray start/stop controller
│   ├── lc0_tray.bat                ← Double-click launcher (pin to taskbar)
│   └── lc0_config.txt              ← Edit: lc0 path, port, threads
│
├── Xcode/
│   └── LeelaChessApp/
│       ├── LeelaChessApp.swift     ← @main SwiftUI entry point
│       ├── Network/
│       │   └── NetworkService.swift  ← WebSocket client, async/await API
│       ├── Engine/
│       │   └── Lc0Player.swift       ← Chess.Player that calls the server
│       ├── Store/
│       │   └── AppStore.swift        ← Wires ChessStore + services together
│       └── Views/
│           └── ContentView.swift     ← Main UI + Settings
│
└── Package.swift                   ← SPM manifest (or add via Xcode GUI)
```

---

## Windows Setup

### 1. Install Python dependencies

Using the provided Conda environment (recommended):

```powershell
conda env create -f Windows/environment.yaml
conda activate lc0-server
```

Or with plain pip if you prefer:

```powershell
pip install websockets pystray pillow
```

### 2. Download lc0

Download the latest Windows release from:
https://github.com/LeelaChessZero/lc0/releases

Extract to `C:\lc0\`. You should have `C:\lc0\lc0.exe`.

### 3. Download a neural network weights file

Get the best network from:
https://lczero.org/play/networks/bestnets/

Place the `.pb.gz` file in `C:\lc0\` and update `lc0_config.txt`:
```
weights = C:\lc0\BT4-1024x15x32h-swa-6147500.pb.gz
```

### 4. Edit lc0_config.txt

```ini
lc0     = C:\lc0\lc0.exe
weights = C:\lc0\<your-weights-file>.pb.gz
port    = 8765
threads = 4
```

### 5. Run the server

**Option A — Double-click**: `lc0_tray.bat` — a system tray icon appears (green = running)

**Option B — Terminal**:
```powershell
python lc0_server.py --lc0 C:\lc0\lc0.exe --port 8765
```

### 6. Add to Windows Startup (optional)

Press **Win + R** → type `shell:startup` → copy a shortcut to `lc0_tray.bat` into that folder.
The server will start automatically when you log in.

### 7. Open Windows Firewall for port 8765

```powershell
# Run as Administrator
netsh advfirewall firewall add rule name="lc0 WebSocket" dir=in action=allow protocol=TCP localport=8765
```

---

## iOS / macOS Xcode Setup

### 1. Create the Xcode Project

- Open Xcode → **File → New → Project**
- Choose **App** (iOS + macOS multiplatform or separate targets)
- Product Name: `LeelaChessApp`, Interface: **SwiftUI**, Language: **Swift**

### 2. Add the swift-chess Package Dependency

- In Xcode: **Project → Package Dependencies → "+"**
- Paste URL: `https://github.com/dpedley/swift-chess`
- Minimum version: `1.0.8`
- Add to your app target

### 3. Add the source files

Copy the files from `Xcode/LeelaChessApp/` into your Xcode project groups:

| File | Group |
|------|-------|
| `LeelaChessApp.swift` | root |
| `Network/NetworkService.swift` | Network |
| `Engine/Lc0Player.swift` | Engine |
| `Store/AppStore.swift` | Store |
| `Views/ContentView.swift` | Views |

### 4. Configure your Tailscale hostname

In the app's **Settings screen** (gear icon), enter:
- **Tailscale Host**: your Windows PC's Tailscale hostname or IP (e.g. `my-gaming-pc` or `100.64.0.5`)
- **Port**: `8765`

Find your PC's Tailscale IP in the Tailscale app or at https://login.tailscale.com/admin/machines

### 5. Build and run

The app will automatically try to connect when launched.

---

## Protocol Reference

### Client → Server

| Command | Payload | Description |
|---------|---------|-------------|
| `analyse` | `{"cmd":"analyse","fen":"...","movetime":2000}` | Get engine eval + best move |
| `engine_move` | `{"cmd":"engine_move","fen":"...","movetime":3000}` | Engine picks and returns a move |
| `ping` | `{"cmd":"ping"}` | Keep-alive |

### Server → Client

| Type | Key fields | Description |
|------|-----------|-------------|
| `analysis` | `bestmove`, `score_cp`, `feedback`, `pv` | Analysis result |
| `engine_move` | `move`, `from`, `to`, `promotion` | Engine's chosen move |
| `pong` | — | Reply to ping |
| `error` | `message` | Something went wrong |

---

## Troubleshooting

**"Not connected" / connection timeout**
- Confirm Tailscale is running on both devices and the PC is reachable (`ping <tailscale-ip>`)
- Check Windows Firewall allows port 8765
- Check `lc0_server.log` in the Windows folder for errors

**lc0 crashes on startup**
- The lc0 binary requires a compatible GPU driver; check your CUDA/DirectML installation
- Try a CPU-only build: download `lc0-…-cpu-dnnl.zip` from the releases page

**Engine never responds**
- Check `lc0_server.log` — the UCI handshake must complete (`lc0 is ready`)
- Try increasing movetime to 5000ms in Settings

**BoardView not rendering**
- Ensure the Chess package was added to the correct target and `import Chess` compiles

---

## License

- **lc0**: GPL-3.0 — https://github.com/LeelaChessZero/lc0
- **swift-chess**: MIT — https://github.com/dpedley/swift-chess
- **This project**: MIT