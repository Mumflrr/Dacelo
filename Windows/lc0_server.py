"""
lc0_server.py — Leela Chess Zero WebSocket Bridge
Runs on your Windows PC. Wraps lc0.exe via UCI protocol and exposes a
WebSocket server that your iOS/macOS app connects to over Tailscale.

Requirements:
    pip install websockets

Usage:
    python lc0_server.py --lc0 "C:/path/to/lc0.exe" --port 8765
"""

import asyncio
import json
import subprocess
import threading
import argparse
import logging
import sys
import os
from typing import Optional

import websockets
from websockets.server import WebSocketServerProtocol

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(os.path.join(os.path.dirname(__file__), "lc0_server.log")),
    ],
)
log = logging.getLogger("lc0_server")


# ── UCI Engine wrapper ────────────────────────────────────────────────────────

class UCIEngine:
    """
    Thin wrapper around an lc0 subprocess communicating via UCI protocol.
    Thread-safe: all subprocess I/O happens on a dedicated reader thread.
    """

    def __init__(self, lc0_path: str, model_path: Optional[str] = None):
        self.lc0_path = lc0_path
        self.model_path = model_path
        self._proc: Optional[subprocess.Popen] = None
        self._lock = asyncio.Lock()
        self._ready = asyncio.Event()
        self._response_queue: asyncio.Queue = asyncio.Queue()
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    def start(self, loop: asyncio.AbstractEventLoop):
        """Launch lc0 and perform UCI handshake."""
        self._loop = loop
        cmd = [self.lc0_path]
        if self.model_path:
            cmd += ["--weights", self.model_path]

        log.info("Launching lc0: %s", " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        # Start background reader thread
        t = threading.Thread(target=self._reader_thread, daemon=True)
        t.start()

        # Send UCI init
        self._write("uci")
        log.info("Sent 'uci', waiting for uciok …")

    def _write(self, cmd: str):
        if self._proc and self._proc.stdin:
            self._proc.stdin.write(cmd + "\n")
            self._proc.stdin.flush()
            log.debug("→ %s", cmd)

    def _reader_thread(self):
        """Background thread: reads stdout lines, routes them to the asyncio queue."""
        for line in iter(self._proc.stdout.readline, ""):
            line = line.rstrip()
            if not line:
                continue
            log.debug("← %s", line)

            # Signal readiness
            if line == "uciok":
                self._loop.call_soon_threadsafe(self._ready.set)
            elif line.startswith("readyok"):
                pass  # handled below via isready/readyok

            # Route everything to response queue
            self._loop.call_soon_threadsafe(self._response_queue.put_nowait, line)

        log.warning("lc0 stdout closed.")

    async def wait_ready(self):
        """Block until UCI handshake completes, then ping isready."""
        await self._ready.wait()
        self._write("isready")
        while True:
            line = await self._response_queue.get()
            if line == "readyok":
                log.info("lc0 is ready.")
                break

    async def analyse(self, fen: str, movetime_ms: int = 2000) -> dict:
        """
        Run analysis on a FEN position.
        Returns dict: {bestmove, score_cp, score_mate, pv, depth}
        """
        async with self._lock:
            # Drain queue
            while not self._response_queue.empty():
                self._response_queue.get_nowait()

            self._write(f"position fen {fen}")
            self._write(f"go movetime {movetime_ms}")

            result = {
                "bestmove": None,
                "score_cp": None,
                "score_mate": None,
                "pv": [],
                "depth": 0,
                "nodes": 0,
            }

            while True:
                line = await asyncio.wait_for(self._response_queue.get(), timeout=30)

                if line.startswith("info"):
                    parts = line.split()
                    try:
                        if "depth" in parts:
                            result["depth"] = int(parts[parts.index("depth") + 1])
                        if "score" in parts:
                            si = parts.index("score")
                            score_type = parts[si + 1]  # "cp" or "mate"
                            score_val = int(parts[si + 2])
                            if score_type == "cp":
                                result["score_cp"] = score_val
                                result["score_mate"] = None
                            elif score_type == "mate":
                                result["score_mate"] = score_val
                                result["score_cp"] = None
                        if "pv" in parts:
                            pi = parts.index("pv")
                            result["pv"] = parts[pi + 1:]
                        if "nodes" in parts:
                            result["nodes"] = int(parts[parts.index("nodes") + 1])
                    except (ValueError, IndexError):
                        pass

                elif line.startswith("bestmove"):
                    parts = line.split()
                    result["bestmove"] = parts[1] if len(parts) > 1 else None
                    return result

    async def get_engine_move(self, fen: str, movetime_ms: int = 3000) -> dict:
        """
        Ask lc0 to pick a move. Same as analyse — bestmove is the engine's choice.
        """
        return await self.analyse(fen, movetime_ms)

    def set_option(self, name: str, value: str):
        self._write(f"setoption name {name} value {value}")

    def stop(self):
        if self._proc:
            try:
                self._write("quit")
                self._proc.wait(timeout=3)
            except Exception:
                self._proc.kill()
            log.info("lc0 stopped.")


# ── WebSocket Message Protocol ────────────────────────────────────────────────
#
# Client → Server (JSON):
#
#   Analyse a position:
#     {"cmd": "analyse", "fen": "<FEN>", "movetime": 2000}
#
#   Engine plays a move:
#     {"cmd": "engine_move", "fen": "<FEN>", "movetime": 3000}
#
#   Ping:
#     {"cmd": "ping"}
#
# Server → Client (JSON):
#
#   Analysis result:
#     {"type": "analysis", "fen": "...", "bestmove": "e2e4",
#      "score_cp": 32, "score_mate": null, "pv": ["e2e4","e7e5"],
#      "depth": 18, "nodes": 50000, "feedback": "Slightly better for White."}
#
#   Engine move:
#     {"type": "engine_move", "move": "e2e4", "from": "e2", "to": "e4",
#      "score_cp": 32, "score_mate": null, "pv": [...]}
#
#   Error:
#     {"type": "error", "message": "..."}
#
#   Pong:
#     {"type": "pong"}


def score_to_feedback(score_cp: Optional[int], score_mate: Optional[int], pov: str = "white") -> str:
    """Convert centipawn score to a human-readable feedback string."""
    if score_mate is not None:
        if score_mate > 0:
            return f"{'White' if pov == 'white' else 'Black'} has mate in {abs(score_mate)}."
        else:
            return f"{'White' if pov == 'white' else 'Black'} is being mated in {abs(score_mate)}."

    if score_cp is None:
        return "Position is unclear."

    cp = score_cp / 100.0  # centipawns → pawns

    if abs(cp) < 0.2:
        return "The position is roughly equal."
    elif abs(cp) < 0.5:
        sign = "+" if cp > 0 else "-"
        return f"Slight {'advantage for White' if cp > 0 else 'advantage for Black'} ({sign}{abs(cp):.2f})."
    elif abs(cp) < 1.5:
        return f"Clear {'advantage for White' if cp > 0 else 'advantage for Black'} ({cp:+.2f})."
    elif abs(cp) < 3.0:
        return f"Large {'advantage for White' if cp > 0 else 'advantage for Black'} ({cp:+.2f})."
    else:
        return f"{'White' if cp > 0 else 'Black'} is winning ({cp:+.2f})."


def uci_move_to_parts(move: str) -> tuple[str, str, Optional[str]]:
    """'e2e4' → ('e2', 'e4', None), 'e7e8q' → ('e7', 'e8', 'q')"""
    if not move or len(move) < 4:
        return ("", "", None)
    from_sq = move[0:2]
    to_sq = move[2:4]
    promo = move[4] if len(move) > 4 else None
    return from_sq, to_sq, promo


# ── WebSocket Handler ─────────────────────────────────────────────────────────

class Lc0Server:
    def __init__(self, engine: UCIEngine, host: str = "0.0.0.0", port: int = 8765):
        self.engine = engine
        self.host = host
        self.port = port
        self._clients: set[WebSocketServerProtocol] = set()

    async def handle(self, ws: WebSocketServerProtocol):
        self._clients.add(ws)
        remote = ws.remote_address
        log.info("Client connected: %s", remote)

        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await ws.send(json.dumps({"type": "error", "message": "Invalid JSON"}))
                    continue

                await self._dispatch(ws, msg)

        except websockets.exceptions.ConnectionClosed:
            log.info("Client disconnected: %s", remote)
        finally:
            self._clients.discard(ws)

    async def _dispatch(self, ws: WebSocketServerProtocol, msg: dict):
        cmd = msg.get("cmd", "")

        if cmd == "ping":
            await ws.send(json.dumps({"type": "pong"}))

        elif cmd == "analyse":
            fen = msg.get("fen", "")
            movetime = int(msg.get("movetime", 2000))
            if not fen:
                await ws.send(json.dumps({"type": "error", "message": "Missing 'fen'"}))
                return

            log.info("Analysing FEN: %s (movetime=%dms)", fen, movetime)
            try:
                result = await self.engine.analyse(fen, movetime)
                from_sq, to_sq, promo = uci_move_to_parts(result["bestmove"] or "")
                # Determine POV from FEN (side to move is field 2)
                pov = "white" if fen.split()[1] == "w" else "black"
                await ws.send(json.dumps({
                    "type": "analysis",
                    "fen": fen,
                    "bestmove": result["bestmove"],
                    "from": from_sq,
                    "to": to_sq,
                    "promotion": promo,
                    "score_cp": result["score_cp"],
                    "score_mate": result["score_mate"],
                    "pv": result["pv"][:5],  # first 5 PV moves
                    "depth": result["depth"],
                    "nodes": result["nodes"],
                    "feedback": score_to_feedback(result["score_cp"], result["score_mate"], pov),
                }))
            except asyncio.TimeoutError:
                await ws.send(json.dumps({"type": "error", "message": "Engine timeout"}))
            except Exception as e:
                log.exception("Analysis error")
                await ws.send(json.dumps({"type": "error", "message": str(e)}))

        elif cmd == "engine_move":
            fen = msg.get("fen", "")
            movetime = int(msg.get("movetime", 3000))
            if not fen:
                await ws.send(json.dumps({"type": "error", "message": "Missing 'fen'"}))
                return

            log.info("Engine move for FEN: %s (movetime=%dms)", fen, movetime)
            try:
                result = await self.engine.get_engine_move(fen, movetime)
                from_sq, to_sq, promo = uci_move_to_parts(result["bestmove"] or "")
                await ws.send(json.dumps({
                    "type": "engine_move",
                    "move": result["bestmove"],
                    "from": from_sq,
                    "to": to_sq,
                    "promotion": promo,
                    "score_cp": result["score_cp"],
                    "score_mate": result["score_mate"],
                    "pv": result["pv"][:5],
                }))
            except asyncio.TimeoutError:
                await ws.send(json.dumps({"type": "error", "message": "Engine timeout"}))
            except Exception as e:
                log.exception("Engine move error")
                await ws.send(json.dumps({"type": "error", "message": str(e)}))

        else:
            await ws.send(json.dumps({"type": "error", "message": f"Unknown command: {cmd}"}))

    async def run(self):
        log.info("WebSocket server starting on ws://%s:%d", self.host, self.port)
        async with websockets.serve(self.handle, self.host, self.port):
            log.info("Server is live. Waiting for connections …")
            await asyncio.Future()  # run forever


# ── Entry Point ───────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(description="lc0 WebSocket Bridge Server")
    parser.add_argument(
        "--lc0",
        default=r"C:\lc0\lc0.exe",
        help="Path to lc0.exe",
    )
    parser.add_argument(
        "--weights",
        default=None,
        help="Path to lc0 weights file (.pb.gz). If omitted, lc0 uses its default.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8765,
        help="WebSocket port to listen on (default: 8765)",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="Bind host (default: 0.0.0.0 — listens on all interfaces including Tailscale)",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=4,
        help="UCI Threads option for lc0 (default: 4)",
    )
    return parser.parse_args()


async def main():
    args = parse_args()

    engine = UCIEngine(lc0_path=args.lc0, model_path=args.weights)
    loop = asyncio.get_running_loop()
    engine.start(loop)

    log.info("Waiting for lc0 UCI handshake …")
    await engine.wait_ready()

    # Configure engine options
    engine.set_option("Threads", str(args.threads))
    engine.set_option("MultiPV", "1")

    server = Lc0Server(engine, host=args.host, port=args.port)
    try:
        await server.run()
    finally:
        engine.stop()


if __name__ == "__main__":
    asyncio.run(main())