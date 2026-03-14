"""
lc0_server.py — Leela Chess Zero WebSocket Bridge

UCI flow (per lc0 docs https://lczero.org/dev/wiki/getting-started/):
  1. start lc0
  2. send "uci"           → lc0 replies with options then "uciok"
  3. send "setoption ..."
  4. send "isready"       → lc0 replies "readyok"
  5. (optionally) "ucinewgame" between games
  6. "position fen <FEN>"
  7. "go movetime <ms>"
  8. lc0 streams "info ..." lines then "bestmove <move>"

Stop the server:
  Ctrl+C in the terminal, or type "quit" + Enter in the terminal.

Dependencies:
  pip install websockets python-chess
"""

import asyncio
import json
import subprocess
import threading
import argparse
import logging
import sys
import os
import math
from typing import Optional

import websockets

try:
    import chess
    HAS_CHESS = True
except ImportError:
    HAS_CHESS = False
    logging.warning("python-chess not installed. Material/mobility/line-type metrics will be unavailable. pip install python-chess")

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


# ── Position metrics (python-chess) ───────────────────────────────────────────

def compute_position_metrics(fen: str) -> dict:
    """
    Compute material balance and piece mobility from FEN.
    Requires python-chess. Returns zeros if unavailable.
    """
    if not HAS_CHESS:
        return {"material_balance": 0, "mobility_white": 0, "mobility_black": 0}
    try:
        board = chess.Board(fen)

        piece_values = {
            chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
            chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0
        }

        white_material = sum(
            piece_values[p.piece_type]
            for p in board.piece_map().values()
            if p.color == chess.WHITE
        )
        black_material = sum(
            piece_values[p.piece_type]
            for p in board.piece_map().values()
            if p.color == chess.BLACK
        )

        # Legal moves for each side — temporarily override turn
        board.turn = chess.WHITE
        white_mobility = len(list(board.legal_moves))
        board.turn = chess.BLACK
        black_mobility = len(list(board.legal_moves))

        return {
            "material_balance": white_material - black_material,
            "mobility_white":   white_mobility,
            "mobility_black":   black_mobility,
        }
    except Exception as e:
        log.warning("compute_position_metrics failed: %s", e)
        return {"material_balance": 0, "mobility_white": 0, "mobility_black": 0}


def classify_line_type(pv: list, fen: str) -> str:
    """
    Classify the line type by examining whether PV moves are
    captures or checks using python-chess. Falls back to heuristics.
    """
    if not HAS_CHESS or not pv:
        return "Quiet"
    try:
        board = chess.Board(fen)
        captures = 0
        checks   = 0
        for uci in pv[:5]:
            try:
                move = chess.Move.from_uci(uci)
                if board.is_capture(move):
                    captures += 1
                if board.gives_check(move):
                    checks += 1
                board.push(move)
            except Exception:
                break

        if checks >= 2 or (captures >= 2 and checks >= 1):
            return "Forcing"
        elif captures >= 2 or checks >= 1:
            return "Tactical"
        elif captures == 1:
            return "Committal"
        elif len(pv) >= 6:
            return "Flexible"
        else:
            return "Quiet"
    except Exception as e:
        log.warning("classify_line_type failed: %s", e)
        return "Quiet"


# ── Position Characteristics ──────────────────────────────────────────────────

def position_characteristics(
    best_cp:    int,
    second_cp:  Optional[int],
    third_cp:   Optional[int],
    pv:         list,
    fen:        str,
    score_drift: int,
) -> dict:
    """
    Compute position characteristics using improved heuristics.

    Sharpness  — spread across all MultiPV scores (how different are the top moves?)
    Difficulty — cp gap between best and second-best (how critical is the choice?)
    Margin     — English label for the same gap
    Line type  — derived from actual capture/check analysis of the PV
    Confidence — how stable was the eval across search depths
    """

    # ── Sharpness: std dev of available MultiPV scores ──────────────────────
    scores = [s for s in [best_cp, second_cp, third_cp] if s is not None]
    if len(scores) >= 2:
        mean   = sum(scores) / len(scores)
        spread = math.sqrt(sum((s - mean) ** 2 for s in scores) / len(scores))
    else:
        spread = 0.0

    if spread < 40:
        sharpness = "Quiet"
    elif spread < 100:
        sharpness = "Balanced"
    elif spread < 220:
        sharpness = "Tactical"
    else:
        sharpness = "Sharp"

    # ── Difficulty: cp gap between best and second best ─────────────────────
    gap = (best_cp - second_cp) if second_cp is not None else 0

    if gap < 20:
        difficulty = "Beginner"
    elif gap < 60:
        difficulty = "Intermediate"
    elif gap < 150:
        difficulty = "Advanced"
    else:
        difficulty = "Expert"

    # ── Margin for error: same gap, different label ──────────────────────────
    if gap < 30:
        margin = "Forgiving"
    elif gap < 100:
        margin = "Moderate"
    else:
        margin = "Narrow"

    # ── Line type: capture/check analysis ───────────────────────────────────
    line_type = classify_line_type(pv, fen)

    # ── Confidence: score drift across depths ───────────────────────────────
    if score_drift < 20:
        confidence = "Confident"
    elif score_drift < 60:
        confidence = "Uncertain"
    else:
        confidence = "Volatile"

    # ── Explanation ──────────────────────────────────────────────────────────
    sharpness_desc = {
        "Quiet":    "Several moves are nearly equal — no single best reply.",
        "Balanced": "There is a best move, but alternatives are reasonable.",
        "Tactical": "The top moves diverge significantly — precision matters.",
        "Sharp":    "Only one move keeps equality — any other loses ground fast.",
    }[sharpness]

    line_desc = {
        "Forcing":   "The principal variation forces the opponent into narrow replies.",
        "Tactical":  "The best line involves concrete tactics — captures or checks.",
        "Committal": "The best move commits to a concrete plan with a capture.",
        "Flexible":  "The best line is long and keeps options open.",
        "Quiet":     "The position calls for quiet improvement — no forcing play.",
    }[line_type]

    explanation = f"{sharpness_desc} {line_desc}"

    return {
        "sharpness":        sharpness,
        "difficulty":       difficulty,
        "margin_for_error": margin,
        "line_type":        line_type,
        "confidence":       confidence,
        "explanation":      explanation,
    }


# ── Score Feedback ────────────────────────────────────────────────────────────

def score_to_feedback(score_cp: Optional[int], score_mate: Optional[int],
                      side_to_move: str = "w") -> str:
    if score_mate is not None:
        if side_to_move == "w":
            winner = "White" if score_mate > 0 else "Black"
        else:
            winner = "Black" if score_mate > 0 else "White"
        n = abs(score_mate)
        return (f"{winner} has mate in {n}." if score_mate > 0
                else f"Opponent has mate in {n}.")

    if score_cp is None:
        return "Position is unclear."

    cp = score_cp / 100.0
    if side_to_move == "b":
        cp = -cp

    if abs(cp) < 0.2:   return "The position is roughly equal."
    favour = "White" if cp > 0 else "Black"
    if abs(cp) < 0.5:   return f"Slight advantage for {favour} ({cp:+.2f})."
    elif abs(cp) < 1.5: return f"Clear advantage for {favour} ({cp:+.2f})."
    elif abs(cp) < 3.0: return f"Large advantage for {favour} ({cp:+.2f})."
    else:               return f"{favour} is winning ({cp:+.2f})."


def uci_to_parts(move: str) -> tuple:
    """'e2e4' → ('e2','e4',None)  |  'e7e8q' → ('e7','e8','q')"""
    if not move or len(move) < 4:
        return "", "", None
    return move[0:2], move[2:4], (move[4] if len(move) > 4 else None)


# ── UCI Engine ────────────────────────────────────────────────────────────────

class UCIEngine:
    """
    Wraps lc0.exe via UCI protocol.
    All engine calls must be serialised through Lc0Server._engine_lock.
    """

    def __init__(self, lc0_path: str, model_path: Optional[str] = None):
        self.lc0_path   = lc0_path
        self.model_path = model_path
        self._proc:  Optional[subprocess.Popen] = None
        self._ready  = asyncio.Event()
        self._queue: asyncio.Queue = asyncio.Queue()
        self._loop:  Optional[asyncio.AbstractEventLoop] = None

    def start(self, loop: asyncio.AbstractEventLoop):
        self._loop = loop
        cmd = [self.lc0_path]
        if self.model_path:
            cmd.append(f"--weights={self.model_path}")
        log.info("Launching: %s", " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        threading.Thread(target=self._reader, daemon=True).start()
        self._send("uci")

    def stop(self):
        if self._proc:
            try:
                self._send("quit")
            except Exception:
                pass
            try:
                self._proc.terminate()
            except Exception:
                pass
            self._proc = None
            log.info("lc0 process stopped.")

    def _send(self, line: str):
        if self._proc and self._proc.stdin:
            self._proc.stdin.write(line + "\n")
            self._proc.stdin.flush()
            log.debug("→ lc0: %s", line)

    def _reader(self):
        """Background thread: pipe lc0 stdout into the asyncio queue."""
        for raw in iter(self._proc.stdout.readline, ""):
            line = raw.rstrip()
            if not line:
                continue
            log.debug("← lc0: %s", line)
            if line == "uciok":
                self._loop.call_soon_threadsafe(self._ready.set)
            self._loop.call_soon_threadsafe(self._queue.put_nowait, line)
        log.warning("lc0 stdout closed")

    async def wait_ready(self):
        await self._ready.wait()
        self._send("isready")
        while True:
            line = await self._queue.get()
            if line == "readyok":
                log.info("lc0 ready")
                return

    def new_game(self):
        self._send("ucinewgame")

    def set_option(self, name: str, value: str):
        self._send(f"setoption name {name} value {value}")

    async def analyse(self, fen: str, movetime_ms: int = 2000) -> dict:
        """
        Analyse FEN with MultiPV. Caller MUST hold Lc0Server._engine_lock.
        Tracks WDL, score stability, and depth/nodes.
        """
        while not self._queue.empty():
            self._queue.get_nowait()

        self._send(f"position fen {fen}")
        self._send(f"go movetime {movetime_ms}")

        mpv:        dict[int, dict] = {}
        best_depth  = 0
        best_nodes  = 0
        timeout     = (movetime_ms / 1000.0) + 15.0

        # Score stability tracking: record eval at each depth for slot 1
        depth_evals: list[int] = []

        # WDL accumulator for the final depth of slot 1
        final_wdl: Optional[tuple[int, int, int]] = None

        while True:
            try:
                line = await asyncio.wait_for(self._queue.get(), timeout=timeout)
            except asyncio.TimeoutError:
                log.error("Timeout waiting for bestmove (fen=%s)", fen)
                self._send("stop")
                raise

            if line.startswith("info"):
                parts = line.split()
                try:
                    if "depth" in parts:
                        d = int(parts[parts.index("depth") + 1])
                        if d > best_depth:
                            best_depth = d
                    if "nodes" in parts:
                        best_nodes = int(parts[parts.index("nodes") + 1])
                except (ValueError, IndexError):
                    pass

                self._parse_info(line, mpv)

                # Track score and WDL at each depth for slot 1
                slot1 = mpv.get(1, {})
                if slot1.get("score_cp") is not None:
                    depth_evals.append(slot1["score_cp"])
                if slot1.get("wdl") is not None:
                    final_wdl = slot1["wdl"]

            elif line.startswith("bestmove"):
                score_drift = self._compute_score_drift(depth_evals)
                return self._build_result(
                    line, mpv, best_depth, best_nodes,
                    score_drift, final_wdl, fen
                )

    def _parse_info(self, line: str, mpv: dict):
        parts = line.split()

        slot = 1
        if "multipv" in parts:
            try:
                slot = int(parts[parts.index("multipv") + 1])
            except (ValueError, IndexError):
                pass

        if slot not in mpv:
            mpv[slot] = {
                "score_cp": None, "score_mate": None,
                "pv": [], "move": None, "wdl": None
            }

        try:
            if "score" in parts:
                si   = parts.index("score")
                kind = parts[si + 1]
                val  = int(parts[si + 2])
                if kind == "cp":
                    mpv[slot]["score_cp"]   = val
                    mpv[slot]["score_mate"] = None
                elif kind == "mate":
                    mpv[slot]["score_mate"] = val
                    mpv[slot]["score_cp"]   = None

            # Parse WDL — lc0 outputs "wdl W D L" (integers summing to 1000)
            if "wdl" in parts:
                wi = parts.index("wdl")
                w  = int(parts[wi + 1])
                d  = int(parts[wi + 2])
                l  = int(parts[wi + 3])
                mpv[slot]["wdl"] = (w, d, l)

            if "pv" in parts:
                pi             = parts.index("pv")
                pv             = parts[pi + 1:]
                mpv[slot]["pv"]   = pv
                mpv[slot]["move"] = pv[0] if pv else None

        except (ValueError, IndexError):
            pass

    def _compute_score_drift(self, depth_evals: list[int]) -> int:
        """
        Max deviation of the eval across all depths from the final eval.
        Measures how stable the search was.
        """
        if len(depth_evals) < 2:
            return 0
        final = depth_evals[-1]
        return max(abs(e - final) for e in depth_evals)

    def _build_result(self, bestmove_line: str, mpv: dict,
                      depth: int, nodes: int,
                      score_drift: int,
                      final_wdl: Optional[tuple],
                      fen: str) -> dict:
        parts    = bestmove_line.split()
        bestmove = parts[1] if len(parts) > 1 else None
        if bestmove == "(none)":
            bestmove = None

        slot1 = mpv.get(1, {})

        alternatives = []
        for rank, s in enumerate(range(2, MULTI_PV + 1), start=2):
            sl = mpv.get(s, {})
            if sl.get("move"):
                alternatives.append({
                    "rank":       rank,
                    "move":       sl["move"],
                    "score_cp":   sl.get("score_cp"),
                    "score_mate": sl.get("score_mate"),
                    "pv":         sl.get("pv", [])[:5],
                })

        # WDL as fractions 0.0–1.0
        wdl_out = None
        if final_wdl is not None:
            w, d, l = final_wdl
            total   = w + d + l or 1
            wdl_out = {
                "white": round(w / total, 4),
                "draw":  round(d / total, 4),
                "black": round(l / total, 4),
            }

        # Position metrics from FEN
        metrics = compute_position_metrics(fen)

        # Characteristics with improved calculations
        second_cp = alternatives[0].get("score_cp") if alternatives else None
        third_cp  = alternatives[1].get("score_cp") if len(alternatives) > 1 else None
        chars = position_characteristics(
            best_cp     = slot1.get("score_cp") or 0,
            second_cp   = second_cp,
            third_cp    = third_cp,
            pv          = slot1.get("pv", []),
            fen         = fen,
            score_drift = score_drift,
        )

        return {
            "bestmove":        bestmove,
            "score_cp":        slot1.get("score_cp"),
            "score_mate":      slot1.get("score_mate"),
            "pv":              slot1.get("pv", []),
            "depth":           depth,
            "nodes":           nodes,
            "score_drift":     score_drift,
            "wdl":             wdl_out,
            "material_balance": metrics["material_balance"],
            "mobility_white":  metrics["mobility_white"],
            "mobility_black":  metrics["mobility_black"],
            "alternatives":    alternatives,
            "characteristics": chars,
        }

    async def get_engine_move(self, fen: str, movetime_ms: int = 3000) -> dict:
        while not self._queue.empty():
            self._queue.get_nowait()

        self._send(f"position fen {fen}")
        self._send(f"go movetime {movetime_ms}")

        best_depth = 0
        best_nodes = 0
        timeout    = (movetime_ms / 1000.0) + 15.0

        while True:
            try:
                line = await asyncio.wait_for(self._queue.get(), timeout=timeout)
            except asyncio.TimeoutError:
                log.error("Timeout waiting for engine move (fen=%s)", fen)
                self._send("stop")
                raise

            if line.startswith("info"):
                parts = line.split()
                try:
                    if "depth" in parts:
                        d = int(parts[parts.index("depth") + 1])
                        if d > best_depth:
                            best_depth = d
                    if "nodes" in parts:
                        best_nodes = int(parts[parts.index("nodes") + 1])
                except (ValueError, IndexError):
                    pass

            elif line.startswith("bestmove"):
                parts    = line.split()
                bestmove = parts[1] if len(parts) > 1 else None
                if bestmove == "(none)":
                    bestmove = None
                return {
                    "bestmove":   bestmove,
                    "score_cp":   None,
                    "score_mate": None,
                    "pv":         [],
                    "depth":      best_depth,
                    "nodes":      best_nodes,
                }


# ── WebSocket Server ──────────────────────────────────────────────────────────

class Lc0Server:
    def __init__(self, engine: UCIEngine, host: str = "0.0.0.0", port: int = 8765):
        self.engine = engine
        self.host   = host
        self.port   = port
        self._clients: set = set()
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

    async def _dispatch(self, ws, msg: dict):
        cmd = msg.get("cmd", "")

        if cmd == "ping":
            await ws.send(json.dumps({"type": "pong"}))

        elif cmd == "new_game":
            self.engine.new_game()
            await ws.send(json.dumps({"type": "new_game_ok"}))

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

                from_sq, to_sq, promo = uci_to_parts(result["bestmove"] or "")
                side_to_move = fen.split()[1] if len(fen.split()) > 1 else "w"

                # Tag alternatives with from/to for the client
                tagged_alts = []
                for alt in result.get("alternatives", []):
                    f, t, p = uci_to_parts(alt.get("move") or "")
                    tagged_alts.append({**alt, "from": f, "to": t, "promotion": p})

                await ws.send(json.dumps({
                    "type":             "analysis",
                    "fen":              fen,
                    "bestmove":         result["bestmove"],
                    "from":             from_sq,
                    "to":               to_sq,
                    "promotion":        promo,
                    "score_cp":         result["score_cp"],
                    "score_mate":       result["score_mate"],
                    "pv":               result["pv"][:8],
                    "depth":            result["depth"],
                    "nodes":            result["nodes"],
                    "score_drift":      result["score_drift"],
                    "wdl":              result["wdl"],
                    "material_balance": result["material_balance"],
                    "mobility_white":   result["mobility_white"],
                    "mobility_black":   result["mobility_black"],
                    "feedback":         score_to_feedback(
                                            result["score_cp"],
                                            result["score_mate"],
                                            side_to_move),
                    "alternatives":     tagged_alts,
                    "characteristics":  result.get("characteristics"),
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
                from_sq, to_sq, promo = uci_to_parts(result["bestmove"] or "")
                await ws.send(json.dumps({
                    "type":       "engine_move",
                    "move":       result["bestmove"],
                    "from":       from_sq,
                    "to":         to_sq,
                    "promotion":  promo,
                    "score_cp":   result["score_cp"],
                    "score_mate": result["score_mate"],
                    "pv":         result["pv"],
                }))
            except asyncio.TimeoutError:
                await ws.send(json.dumps({"type": "error", "message": "Engine timeout"}))
            except Exception as e:
                log.exception("Engine move error")
                await ws.send(json.dumps({"type": "error", "message": str(e)}))

        else:
            await ws.send(json.dumps({"type": "error",
                                       "message": f"Unknown command: {cmd}"}))

    async def run(self):
        log.info("WebSocket server on ws://%s:%d", self.host, self.port)
        async with websockets.serve(self.handle, self.host, self.port):
            log.info("Server live — waiting for connections  (Ctrl+C or type 'quit' to stop)")
            await asyncio.Future()


# ── stdin "quit" listener ─────────────────────────────────────────────────────

def _stdin_quit_watcher(loop: asyncio.AbstractEventLoop):
    try:
        for line in sys.stdin:
            if line.strip().lower() in ("quit", "exit", "q"):
                log.info("Quit command received — shutting down.")
                loop.call_soon_threadsafe(loop.stop)
                break
    except Exception:
        pass


# ── Entry Point ───────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="lc0 WebSocket Bridge")
    p.add_argument("--lc0",     default=r"lc0\lc0.exe",    help="Path to lc0.exe")
    p.add_argument("--weights", default=r"lc0\BT4-332.pb", help="Path to weights (.pb)")
    p.add_argument("--port",    type=int, default=8765,     help="WebSocket port")
    p.add_argument("--host",    default="0.0.0.0",          help="Bind address")
    p.add_argument("--threads", type=int, default=4,        help="UCI Threads option")
    return p.parse_args()


async def main():
    args         = parse_args()
    lc0_path     = os.path.abspath(args.lc0)
    weights_path = os.path.abspath(args.weights)
    log.info("lc0 exe     : %s  (exists=%s)", lc0_path,     os.path.exists(lc0_path))
    log.info("weights     : %s  (exists=%s)", weights_path, os.path.exists(weights_path))
    log.info("port        : %d", args.port)
    log.info("threads     : %d", args.threads)
    log.info("python-chess: %s", "available" if HAS_CHESS else "NOT INSTALLED — pip install python-chess")

    engine = UCIEngine(lc0_path=lc0_path, model_path=weights_path)
    loop   = asyncio.get_running_loop()
    engine.start(loop)

    threading.Thread(target=_stdin_quit_watcher, args=(loop,), daemon=True).start()

    log.info("Waiting for UCI handshake …")
    await engine.wait_ready()

    engine.set_option("Threads", str(args.threads))
    engine.set_option("MultiPV",  str(MULTI_PV))

    server = Lc0Server(engine, host=args.host, port=args.port)
    try:
        await server.run()
    except (KeyboardInterrupt, asyncio.CancelledError):
        log.info("Shutting down…")
    finally:
        engine.stop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Stopped by Ctrl+C.")