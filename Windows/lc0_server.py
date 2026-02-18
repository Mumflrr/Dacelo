"""
lc0_server.py — Leela Chess Zero WebSocket Bridge
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

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(os.path.join(os.path.dirname(__file__), "lc0_server.log")),
    ],
)
log = logging.getLogger("lc0_server")

MULTI_PV = 3


class UCIEngine:
    def __init__(self, lc0_path: str, model_path: Optional[str] = None):
        self.lc0_path = lc0_path
        self.model_path = model_path
        self._proc: Optional[subprocess.Popen] = None
        self._ready = asyncio.Event()
        self._response_queue: asyncio.Queue = asyncio.Queue()
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    def start(self, loop: asyncio.AbstractEventLoop):
        self._loop = loop
        cmd = [self.lc0_path]
        if self.model_path:
            cmd += ["--weights", self.model_path]
        log.info("Launching lc0: %s", " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        threading.Thread(target=self._reader_thread, daemon=True).start()
        self._write("uci")

    def _write(self, cmd: str):
        if self._proc and self._proc.stdin:
            self._proc.stdin.write(cmd + "\n")
            self._proc.stdin.flush()
            log.debug("→ %s", cmd)

    def _reader_thread(self):
        for line in iter(self._proc.stdout.readline, ""):
            line = line.rstrip()
            if not line:
                continue
            log.debug("← %s", line)
            if line == "uciok":
                self._loop.call_soon_threadsafe(self._ready.set)
            self._loop.call_soon_threadsafe(self._response_queue.put_nowait, line)
        log.warning("lc0 stdout closed.")

    async def wait_ready(self):
        await self._ready.wait()
        self._write("isready")
        while True:
            line = await self._response_queue.get()
            if line == "readyok":
                log.info("lc0 is ready.")
                break

    async def analyse(self, fen: str, movetime_ms: int = 2000) -> dict:
        """
        Analyse position with MultiPV. Caller MUST hold Lc0Server._engine_lock.
        Returns bestmove, scores, alternatives list, and position characteristics.
        """
        while not self._response_queue.empty():
            self._response_queue.get_nowait()

        self._write(f"position fen {fen}")
        self._write(f"go movetime {movetime_ms}")

        # Track latest data per multipv slot: {slot: {score_cp, score_mate, pv, move}}
        mpv: dict[int, dict] = {}
        best_depth = 0
        best_nodes = 0
        timeout_secs = (movetime_ms / 1000.0) + 10.0

        while True:
            try:
                line = await asyncio.wait_for(self._response_queue.get(), timeout=timeout_secs)
            except asyncio.TimeoutError:
                log.error("Engine timed out (fen=%s)", fen)
                self._write("stop")
                raise

            if line.startswith("info"):
                parts = line.split()
                try:
                    slot = 1
                    if "multipv" in parts:
                        slot = int(parts[parts.index("multipv") + 1])
                    if slot not in mpv:
                        mpv[slot] = {"score_cp": None, "score_mate": None, "pv": [], "move": None}
                    if "depth" in parts:
                        d = int(parts[parts.index("depth") + 1])
                        if d > best_depth:
                            best_depth = d
                    if "nodes" in parts:
                        best_nodes = int(parts[parts.index("nodes") + 1])
                    if "score" in parts:
                        si = parts.index("score")
                        kind, val = parts[si + 1], int(parts[si + 2])
                        if kind == "cp":
                            mpv[slot]["score_cp"]   = val
                            mpv[slot]["score_mate"] = None
                        elif kind == "mate":
                            mpv[slot]["score_mate"] = val
                            mpv[slot]["score_cp"]   = None
                    if "pv" in parts:
                        pi  = parts.index("pv")
                        pv  = parts[pi + 1:]
                        mpv[slot]["pv"]   = pv
                        mpv[slot]["move"] = pv[0] if pv else None
                except (ValueError, IndexError):
                    pass

            elif line.startswith("bestmove"):
                parts    = line.split()
                bestmove = parts[1] if len(parts) > 1 else None
                slot1    = mpv.get(1, {})

                alternatives = []
                for slot_num in sorted(mpv.keys()):
                    s    = mpv[slot_num]
                    move = s.get("move")
                    if not move:
                        continue
                    from_sq, to_sq, promo = uci_move_to_parts(move)
                    alternatives.append({
                        "rank":       slot_num,
                        "move":       move,
                        "from":       from_sq,
                        "to":         to_sq,
                        "promotion":  promo,
                        "score_cp":   s.get("score_cp"),
                        "score_mate": s.get("score_mate"),
                    })

                return {
                    "bestmove":        bestmove,
                    "score_cp":        slot1.get("score_cp"),
                    "score_mate":      slot1.get("score_mate"),
                    "pv":              slot1.get("pv", []),
                    "depth":           best_depth,
                    "nodes":           best_nodes,
                    "alternatives":    alternatives,
                    "characteristics": calculate_characteristics(mpv),
                }

    async def get_engine_move(self, fen: str, movetime_ms: int = 3000) -> dict:
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


# ── Characteristics ───────────────────────────────────────────────────────────

def calculate_characteristics(mpv: dict) -> dict:
    """
    Calculate position characteristics from the gap between best and 2nd-best moves.

    Gap thresholds (in pawns):
      Sharpness:  >1.5 Sharp | >0.5 Tactical | >0.2 Balanced | else Quiet
      Difficulty: <0.1 Expert | <0.3 Advanced | <0.8 Intermediate | else Beginner
      Margin:     >1.0 Narrow | >0.3 Moderate | else Forgiving
      Line type:  >1.5 Forcing | >0.8 Committal | >0.2 Flexible | else Quiet
    """
    s1 = mpv.get(1, {}).get("score_cp")
    s2 = mpv.get(2, {}).get("score_cp")

    if s1 is None or s2 is None:
        return {
            "sharpness": "Balanced", "difficulty": "Intermediate",
            "margin_for_error": "Moderate", "line_type": "Flexible",
            "explanation": "Position requires standard play.",
        }

    gap = abs(s1 - s2) / 100.0  # centipawns → pawns

    if gap > 1.5:   sharpness = "Sharp"
    elif gap > 0.5: sharpness = "Tactical"
    elif gap > 0.2: sharpness = "Balanced"
    else:           sharpness = "Quiet"

    if gap < 0.1:   difficulty = "Expert"
    elif gap < 0.3: difficulty = "Advanced"
    elif gap < 0.8: difficulty = "Intermediate"
    else:           difficulty = "Beginner"

    if gap > 1.0:   margin = "Narrow"
    elif gap > 0.3: margin = "Moderate"
    else:           margin = "Forgiving"

    if gap > 1.5:   line_type = "Forcing"
    elif gap > 0.8: line_type = "Committal"
    elif gap > 0.2: line_type = "Flexible"
    else:           line_type = "Quiet"

    # Build explanation
    parts = []
    parts.append({
        "Sharp":    "Only one good move — critical position.",
        "Tactical": "Accuracy matters; some moves are clearly better than others.",
        "Balanced": "Multiple reasonable options available.",
        "Quiet":    "Many moves are roughly equal.",
    }[sharpness])
    parts.append({
        "Expert":       "Requires deep calculation.",
        "Advanced":     "Subtle differences demand careful study.",
        "Intermediate": "Best move is findable with focused thought.",
        "Beginner":     "The best move stands out clearly.",
    }[difficulty])
    parts.append({
        "Narrow":    f"Only the best move maintains the advantage (gap: {gap:.2f}p).",
        "Moderate":  "Best move preferred, but alternatives are viable.",
        "Forgiving": "Several moves keep the advantage.",
    }[margin])
    parts.append({
        "Forcing":    "Forces the opponent into a narrow reply.",
        "Committal":  "Creates imbalances — commits to a clear plan.",
        "Flexible":   "Keeps options open for follow-up play.",
        "Quiet":      "Maneuvering — incremental improvement.",
    }[line_type])

    return {
        "sharpness":        sharpness,
        "difficulty":       difficulty,
        "margin_for_error": margin,
        "line_type":        line_type,
        "explanation":      " ".join(parts),
    }


# ── Helpers ───────────────────────────────────────────────────────────────────

def score_to_feedback(score_cp, score_mate, pov="white"):
    if score_mate is not None:
        side = "White" if pov == "white" else "Black"
        return (f"{side} has mate in {abs(score_mate)}." if score_mate > 0
                else f"{side} is being mated in {abs(score_mate)}.")
    if score_cp is None:
        return "Position is unclear."
    cp = score_cp / 100.0
    if abs(cp) < 0.2:   return "The position is roughly equal."
    elif abs(cp) < 0.5: return f"Slight {'advantage for White' if cp > 0 else 'advantage for Black'} ({cp:+.2f})."
    elif abs(cp) < 1.5: return f"Clear {'advantage for White' if cp > 0 else 'advantage for Black'} ({cp:+.2f})."
    elif abs(cp) < 3.0: return f"Large {'advantage for White' if cp > 0 else 'advantage for Black'} ({cp:+.2f})."
    else:               return f"{'White' if cp > 0 else 'Black'} is winning ({cp:+.2f})."


def uci_move_to_parts(move):
    if not move or len(move) < 4:
        return "", "", None
    return move[0:2], move[2:4], (move[4] if len(move) > 4 else None)


# ── WebSocket Handler ─────────────────────────────────────────────────────────

class Lc0Server:
    def __init__(self, engine, host="0.0.0.0", port=8765):
        self.engine = engine
        self.host   = host
        self.port   = port
        self._clients = set()
        # Single global lock — UCI engine is single-threaded; never concurrent.
        self._engine_lock = asyncio.Lock()

    async def handle(self, ws):
        self._clients.add(ws)
        log.info("Client connected: %s", ws.remote_address)
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await ws.send(json.dumps({"type": "error", "message": "Invalid JSON"}))
                    continue
                await self._dispatch(ws, msg)
        except websockets.exceptions.ConnectionClosed:
            log.info("Client disconnected: %s", ws.remote_address)
        finally:
            self._clients.discard(ws)

    async def _dispatch(self, ws, msg):
        cmd = msg.get("cmd", "")

        if cmd == "ping":
            await ws.send(json.dumps({"type": "pong"}))

        elif cmd == "analyse":
            fen      = msg.get("fen", "")
            movetime = int(msg.get("movetime", 2000))
            if not fen:
                await ws.send(json.dumps({"type": "error", "message": "Missing 'fen'"}))
                return
            log.info("Analysing FEN: %s (movetime=%dms)", fen, movetime)
            try:
                async with self._engine_lock:
                    result = await self.engine.analyse(fen, movetime)
                from_sq, to_sq, promo = uci_move_to_parts(result["bestmove"] or "")
                pov = "white" if fen.split()[1] == "w" else "black"
                await ws.send(json.dumps({
                    "type":            "analysis",
                    "fen":             fen,
                    "bestmove":        result["bestmove"],
                    "from":            from_sq,
                    "to":              to_sq,
                    "promotion":       promo,
                    "score_cp":        result["score_cp"],
                    "score_mate":      result["score_mate"],
                    "pv":              result["pv"][:5],
                    "depth":           result["depth"],
                    "nodes":           result["nodes"],
                    "feedback":        score_to_feedback(result["score_cp"], result["score_mate"], pov),
                    "alternatives":    result.get("alternatives", []),
                    "characteristics": result.get("characteristics"),
                }))
            except asyncio.TimeoutError:
                await ws.send(json.dumps({"type": "error", "message": "Engine timeout"}))
            except Exception as e:
                log.exception("Analysis error")
                await ws.send(json.dumps({"type": "error", "message": str(e)}))

        elif cmd == "engine_move":
            fen      = msg.get("fen", "")
            movetime = int(msg.get("movetime", 3000))
            if not fen:
                await ws.send(json.dumps({"type": "error", "message": "Missing 'fen'"}))
                return
            log.info("Engine move for FEN: %s (movetime=%dms)", fen, movetime)
            try:
                async with self._engine_lock:
                    result = await self.engine.get_engine_move(fen, movetime)
                from_sq, to_sq, promo = uci_move_to_parts(result["bestmove"] or "")
                await ws.send(json.dumps({
                    "type":       "engine_move",
                    "move":       result["bestmove"],
                    "from":       from_sq,
                    "to":         to_sq,
                    "promotion":  promo,
                    "score_cp":   result["score_cp"],
                    "score_mate": result["score_mate"],
                    "pv":         result["pv"][:5],
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
            await asyncio.Future()


# ── Entry Point ───────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="lc0 WebSocket Bridge Server")
    p.add_argument("--lc0",     default=r"C:\lc0\lc0.exe")
    p.add_argument("--weights", default=None)
    p.add_argument("--port",    type=int, default=8765)
    p.add_argument("--host",    default="0.0.0.0")
    p.add_argument("--threads", type=int, default=4)
    return p.parse_args()


async def main():
    args   = parse_args()
    engine = UCIEngine(lc0_path=args.lc0, model_path=args.weights)
    loop   = asyncio.get_running_loop()
    engine.start(loop)
    log.info("Waiting for lc0 UCI handshake …")
    await engine.wait_ready()
    engine.set_option("Threads", str(args.threads))
    engine.set_option("MultiPV",  str(MULTI_PV))   # 3 alternatives
    server = Lc0Server(engine, host=args.host, port=args.port)
    try:
        await server.run()
    finally:
        engine.stop()


if __name__ == "__main__":
    asyncio.run(main())