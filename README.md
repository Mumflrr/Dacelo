# LeelaChessApp — iOS/macOS ↔ Windows PC via Tailscale

A chess app where your Apple devices use **Leela Chess Zero (lc0)** running on Windows PC
as the AI engine. Communication happens over **Tailscale** private network. Allows for
Player vs Engine with move analysis.

---

## Architecture Overview

```
┌─────────────────────────────┐        Tailscale VPN        ┌──────────────────────────────┐
│      iOS / macOS App        │  ◄── WebSocket (JSON) ──►   │        Windows PC            │
│                             │                             │                              │
│  SwiftUI BoardView          │                             │  lc0_server.py               │
│  (swift-chess package)      │                             │   ├── WebSocket server :8765 │
│                             │                             │   └── lc0.exe (UCI pipe)     │
│  ChessStore (Combine)       │                             │                              │
│  AppStore (ObservableObj)   │                             │  lc0_tray.py                 │
│  NetworkService (WebSocket) │                             │   └── System tray on/off     │
│  Lc0Player (custom player)  │                             │                              │
│  AnalysisService            │                             │  lc0.exe + weights .pb.g     │
└─────────────────────────────┘                             └──────────────────────────────┘
```

### Data Flow

1. User taps a move on the board → swift-chess `ChessStore` updates game state
2. If it's the engine's turn → `Lc0Player.move()` fires
3. `NetworkService.engineMove(fen:)` sends JSON over WebSocket to PC
4. `lc0_server.py` pipes `position fen … go movetime …` to `lc0.exe`
5. lc0 replies; server sends JSON back
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
│       ├── LeelaChessApp.swift       ← @main SwiftUI entry point
│       ├── Network/
│       │   └── NetworkService.swift  ← WebSocket client, async/await API
│       ├── Engine/
│       │   └── Lc0Player.swift       ← Chess.Player that calls the server
│       ├── Store/
│       │   └── AppStore.swift        ← Wires ChessStore + services together
│       ├── Views/
│       │   └── ContentView.swift     ← Main UI + Settings
│       └── AnalysisService/
│           └── Analysis.swift        ← Control how analysis operates
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

**Optional — cuDNN for better performance (NVIDIA GPUs only):**

If you have an NVIDIA GPU and want ~10-15% faster analysis, install cuDNN via conda:

```powershell
conda activate lc0-server
conda install -c conda-forge cudnn
```

Then download the `cudnn` lc0 release instead of `cuda12`. Conda manages the DLLs automatically.

### 2. Download lc0

Download the latest Windows release from:
https://github.com/LeelaChessZero/lc0/releases

**Which version to download:**
- **NVIDIA GPU**: Use `cuda12` (includes all DLLs, easiest) or `cudnn` for slightly better performance
- **AMD/Intel GPU or CPU-only**: Use `cpu-dnnl` or `openblas`
- **Using conda**: See cuDNN setup below for best performance

Extract to base repo folder. You should have `path/to/repo/Windows/lc0/lc0.exe`.

### 3. Download a neural network weights file

Get the best network from:
https://lczero.org/play/networks/bestnets/

Place the `.pb.gz` (or extracted `.pb`) file in base repo folder and update `lc0_config.txt`:
```
weights = path\to\repo\Windows\lc0\<weights-file>.pb(.gz)
```

### 4. Edit lc0_config.txt

```ini
lc0     = path/to/repo/Windows/lc0/lc0.exe
weights = path/to/repo/Windows/lc0/<weights-file>.pb.gz
port    = 8765
threads = 4
```

### 5. Run the server

**Option A — Double-click**: `lc0_tray.bat` — a system tray icon appears (green = running)

**Option B — Terminal**:
```powershell
python lc0_server.py --lc0 ./lc0/lc0.exe --port 8765
```
**Port 8765** is arbitrary — you can use any port above 1024. Just update both `lc0_config.txt` and the app's Settings to match.


### 6. Add to Windows Startup (optional)

Press **Win + R** → type `shell:startup` → copy a shortcut to `lc0_tray.bat` into that folder.
The server will start automatically when you log in.

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

### 4. Configure network permissions

**For macOS:** 
- Click your target → **Signing & Capabilities** tab → **+ Capability** → **App Sandbox**
- Under App Sandbox, check **✅ Outgoing Connections (Client)**

**For iOS:**
- Click your target → **Info** tab → Add these three keys:

| Key | Type | Value |
|-----|------|-------|
| `App Transport Security Settings` | Dictionary | (add sub-keys below) |
| └─ `Allow Arbitrary Loads in Web Content` | Boolean | `YES` |
| `Privacy - Local Network Usage Description` | String | `"Connect to Windows PC via Tailscale for lc0 analysis"` |
| `Bonjour services` | Array | Item 0: `_ws._tcp` |

These allow plain WebSocket (`ws://`) over your Tailscale VPN and trigger the local network permission prompt on iOS.

### 5. Configure your Tailscale hostname

In the app's **Settings screen** (gear icon), enter:
- **Tailscale Host**: your Windows PC's Tailscale hostname or IP (e.g. `my-gaming-pc` or `100.64.0.5`)
- **Port**: `8765`

Find your PC's Tailscale IP in the Tailscale app or at https://login.tailscale.com/admin/machines

### 6. Build and run

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

**Conda "command not found" on Windows**
- Open **Anaconda Prompt** (not PowerShell) → run `conda init powershell` and `conda init cmd.exe`
- Open PowerShell **as Administrator** → run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`
- Close and reopen all terminal windows for changes to take effect
- If still broken, manually add these to your PATH: `C:\Users\<YourUsername>\miniconda3`, `...\Scripts`, `...\condabin`

**"Not connected" / connection timeout**
- Confirm Tailscale is running on both devices and the PC is reachable: `ping <tailscale-ip>` from your Mac/iPhone
- If using Tailscale, you do NOT need to open Windows Firewall (the `100.x.x.x` IP bypasses it)
- Check `lc0_server.log` in the Windows folder for errors
- Make sure you entered the correct Tailscale IP in the app's Settings (not your public IP)

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