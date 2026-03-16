"""
chess_server.py — Model-Agnostic UCI WebSocket Bridge

Supports any number of UCI engines registered via --engine flags.

Usage:
    python chess_server.py \
        --engine lc0=lc0/lc0.exe:lc0/BT4-332.pb \
        --engine stockfish=sf/stockfish.exe \
        --primary lc0 \
        --port 8765 \
        --threads 4

Engine spec format:  NAME=EXE[:WEIGHTS]
  --engine lc0=path/to/lc0.exe:path/to/weights.pb
  --engine stockfish=path/to/stockfish.exe
  (weights are optional; lc0 needs them, Stockfish does not)

The --primary flag sets which engine name the clients get when they
request engine "primary" (or omit the engine field entirely).
Defaults to the first --engine registered.

Stop the server:
  Ctrl+C, or type "quit" + Enter.

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
    logging.warning(
        "python-chess not installed — material/mobility/line-type metrics "
        "unavailable. pip install python-chess"
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(
            os.path.join(os.path.dirname(__file__), "chess_server.log")
        ),
    ],
)
log = logging.getLogger("chess_server")

MULTI_PV = 3


# ── Position metrics (python-chess) ──────────────────────────────────────────

def compute_position_metrics(fen: str) -> dict:
    if not HAS_CHESS:
        return {"material_balance": 0, "mobility_white": 0, "mobility_black": 0}
    try:
        board = chess.Board(fen)
        piece_values = {
            chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
            chess.ROOK: 5, chess.QUEEN: 9, chess.KING: 0,
        }
        white_material = sum(
            piece_values[p.piece_type]
            for p in board.piece_map().values() if p.color == chess.WHITE
        )
        black_material = sum(
            piece_values[p.piece_type]
            for p in board.piece_map().values() if p.color == chess.BLACK
        )
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
    if not HAS_CHESS or not pv:
        return "Quiet"
    try:
        board = chess.Board(fen)
        captures = checks = 0
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


# ── Pawn structure analysis ──────────────────────────────────────────────────

def pawn_structure(fen: str) -> dict:
    """
    Identify pawn structure features using python-chess.
    Returns counts of isolated, doubled, and passed pawns per side,
    plus an overall structure label.
    """
    if not HAS_CHESS:
        return {}
    try:
        board = chess.Board(fen)

        def get_pawns(color):
            return list(board.pieces(chess.PAWN, color))

        def files_of(squares):
            return [chess.square_file(s) for s in squares]

        def is_isolated(sq, own_files):
            f = chess.square_file(sq)
            return (f - 1) not in own_files and (f + 1) not in own_files

        def is_doubled(sq, own_squares):
            f = chess.square_file(sq)
            r = chess.square_rank(sq)
            return any(chess.square_file(s) == f and chess.square_rank(s) != r
                       for s in own_squares)

        def is_passed(sq, color, opp_pawns):
            f   = chess.square_file(sq)
            r   = chess.square_rank(sq)
            fwd = range(r + 1, 8) if color == chess.WHITE else range(0, r)
            adj = [f - 1, f, f + 1]
            for op in opp_pawns:
                if chess.square_file(op) in adj and chess.square_rank(op) in fwd:
                    return False
            return True

        results = {}
        for color, label in [(chess.WHITE, "white"), (chess.BLACK, "black")]:
            pawns     = get_pawns(color)
            opp_pawns = get_pawns(not color)
            own_files = files_of(pawns)
            isolated  = sum(1 for p in pawns if is_isolated(p, own_files))
            doubled   = sum(1 for p in pawns if is_doubled(p, pawns))
            passed    = sum(1 for p in pawns if is_passed(p, color, opp_pawns))
            results[f"isolated_{label}"] = isolated
            results[f"doubled_{label}"]  = doubled
            results[f"passed_{label}"]   = passed

        # Overall structure label for the UI
        total_isolated = results["isolated_white"] + results["isolated_black"]
        total_passed   = results["passed_white"]   + results["passed_black"]
        if total_passed >= 2:
            structure = "Endgame-like"
        elif total_isolated >= 3:
            structure = "Weakened"
        else:
            board.turn = chess.WHITE
            open_files = sum(
                1 for f in range(8)
                if not any(chess.square_file(s) == f
                           for s in get_pawns(chess.WHITE) + get_pawns(chess.BLACK))
            )
            structure = "Open" if open_files >= 2 else "Closed" if open_files == 0 else "Semi-open"

        results["structure"] = structure
        return results
    except Exception as e:
        log.warning("pawn_structure failed: %s", e)
        return {}


# ── King safety ───────────────────────────────────────────────────────────────

def king_safety(fen: str) -> dict:
    """
    Count attackers near each king and whether the king is castled.
    Quick heuristic: squares in the king zone (3x2 in front of king)
    attacked by the opponent.
    """
    if not HAS_CHESS:
        return {}
    try:
        board = chess.Board(fen)
        results = {}
        for color, label in [(chess.WHITE, "white"), (chess.BLACK, "black")]:
            king_sq  = board.king(color)
            if king_sq is None:
                continue
            opp = not color
            kr  = chess.square_rank(king_sq)
            kf  = chess.square_file(king_sq)
            # Zone: king square + adjacent squares in the forward direction
            fwd = 1 if color == chess.WHITE else -1
            zone = []
            for df in [-1, 0, 1]:
                for dr in [0, fwd, 2 * fwd]:
                    r2, f2 = kr + dr, kf + df
                    if 0 <= r2 <= 7 and 0 <= f2 <= 7:
                        zone.append(chess.square(f2, r2))
            attackers = sum(
                1 for sq in zone if board.is_attacked_by(opp, sq)
            )
            # Simple castled heuristic: king on g or c file (kingside/queenside)
            castled = kf in (6, 2) and kr in (0, 7)
            results[f"king_attackers_{label}"] = attackers
            results[f"king_castled_{label}"]   = castled
        return results
    except Exception as e:
        log.warning("king_safety failed: %s", e)
        return {}


# ── Game phase ────────────────────────────────────────────────────────────────

def game_phase(fen: str) -> str:
    """
    Classify position as Opening / Middlegame / Endgame.
    Based on total minor+major piece count (excludes kings and pawns).
    """
    if not HAS_CHESS:
        return "Middlegame"
    try:
        board = chess.Board(fen)
        major_minor = sum(
            1 for p in board.piece_map().values()
            if p.piece_type in (chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN)
        )
        # Fullmove counter for opening heuristic
        parts    = fen.split()
        fullmove = int(parts[5]) if len(parts) > 5 else 1
        if major_minor >= 12 and fullmove <= 12:
            return "Opening"
        elif major_minor <= 6:
            return "Endgame"
        else:
            return "Middlegame"
    except Exception as e:
        log.warning("game_phase failed: %s", e)
        return "Middlegame"


# ── Position Characteristics ──────────────────────────────────────────────────

def position_characteristics(
    best_cp:     int,
    second_cp:   Optional[int],
    third_cp:    Optional[int],
    pv:          list,
    fen:         str,
    score_drift: int,
) -> dict:
    scores = [s for s in [best_cp, second_cp, third_cp] if s is not None]
    if len(scores) >= 2:
        mean   = sum(scores) / len(scores)
        spread = math.sqrt(sum((s - mean) ** 2 for s in scores) / len(scores))
    else:
        spread = 0.0

    # ── Position type: how equal are the top moves? ──────────────────────────
    # Renamed from "sharpness" to avoid confusion with line_type.
    # "Equal" means multiple moves are nearly as good — low pressure.
    # "Critical" means one move is clearly best — high stakes.
    if spread < 40:
        position_type = "Equal"
    elif spread < 100:
        position_type = "Unbalanced"
    elif spread < 220:
        position_type = "Complex"
    else:
        position_type = "Critical"

    # ── Move precision required: gap between best and second-best ────────────
    # Previously called "difficulty" but that implies player skill level.
    # This specifically measures how much better the top move is than the rest.
    gap = (best_cp - second_cp) if second_cp is not None else 0

    if gap < 20:
        precision_required = "Low"        # Several moves are roughly equal
    elif gap < 60:
        precision_required = "Moderate"   # Best move is noticeably better
    elif gap < 150:
        precision_required = "High"       # Only 1-2 moves maintain the advantage
    else:
        precision_required = "Very High"  # One move only — miss it and lose ground fast

    # ── Eval stability: how much did the score drift during search? ──────────
    # Previously called "confidence" which implies the engine is confident.
    # Renamed to clarify this is about search stability, not engine certainty.
    # Volatile = the score changed a lot across depths (position is hard to evaluate).
    if score_drift < 20:
        eval_stability = "Stable"
    elif score_drift < 60:
        eval_stability = "Fluctuating"
    else:
        eval_stability = "Volatile"

    # ── Line type ────────────────────────────────────────────────────────────
    line_type = classify_line_type(pv, fen)

    # ── Explanation ──────────────────────────────────────────────────────────
    type_desc = {
        "Equal":      "Multiple moves are nearly as good — you have flexibility here.",
        "Unbalanced": "One move is better, but alternatives are reasonable.",
        "Complex":    "The top moves diverge significantly — precision matters.",
        "Critical":   "One move keeps equality. The others lose ground fast.",
    }[position_type]

    line_desc = {
        "Forcing":   "The best line forces your opponent into narrow replies.",
        "Tactical":  "The best continuation involves concrete tactics — captures or checks.",
        "Committal": "The best move commits to a plan with an immediate capture.",
        "Flexible":  "The best line is long and keeps many options open.",
        "Quiet":     "The position calls for quiet improvement — no forcing play.",
    }[line_type]

    precision_desc = {
        "Low":       "Several moves maintain the position well.",
        "Moderate":  "The best move is noticeably better than alternatives.",
        "High":      "Only one or two moves hold the advantage.",
        "Very High": "One move only — the others give away significant ground.",
    }[precision_required]

    stability_desc = {
        "Stable":      "The engine's evaluation was consistent across search depths.",
        "Fluctuating": "The evaluation changed somewhat during search — some uncertainty.",
        "Volatile":    "The evaluation changed significantly during search — hard-to-read position.",
    }[eval_stability]

    return {
        "position_type":       position_type,
        "precision_required":  precision_required,
        "eval_stability":      eval_stability,
        "line_type":           line_type,
        # Keep legacy keys for backwards compat with any existing UI code
        "sharpness":           position_type,
        "difficulty":          precision_required,
        "confidence":          eval_stability,
        "margin_for_error":    precision_required,
        "explanation":         f"{type_desc} {line_desc} {precision_desc}",
        "stability_note":      stability_desc,
    }


# ── Score Feedback ────────────────────────────────────────────────────────────

def score_to_feedback(
    score_cp:    Optional[int],
    score_mate:  Optional[int],
    side_to_move: str = "w",
) -> str:
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

    if abs(cp) < 0.2:
        return "The position is roughly equal."

    favour = "White" if cp > 0 else "Black"

    if abs(cp) < 0.5:
        return f"Slight advantage for {favour} ({cp:+.2f})."
    elif abs(cp) < 1.5:
        return f"Clear advantage for {favour} ({cp:+.2f})."
    elif abs(cp) < 3.0:
        return f"Large advantage for {favour} ({cp:+.2f})."
    else:
        return f"{favour} is winning ({cp:+.2f})."


def uci_to_parts(move: str) -> tuple:
    """'e2e4' → ('e2','e4',None)  |  'e7e8q' → ('e7','e8','q')"""
    if not move or len(move) < 4:
        return "", "", None
    return move[0:2], move[2:4], (move[4] if len(move) > 4 else None)


# ── NNUE parser (Stockfish info strings) ─────────────────────────────────────

def parse_stockfish_eval(info_lines: list) -> Optional[dict]:
    """
    Parse Stockfish's 'info string' NNUE eval breakdown.
    Returns a dict of term -> {white, black, total} in pawns, or None.
    """
    terms = {}
    in_table = False
    for line in info_lines:
        if "NNUE evaluation" in line or "Classical evaluation" in line:
            in_table = True
            continue
        if not in_table:
            continue
        if "Term" in line or "---" in line or ("Total" in line and "term" not in line.lower()):
            continue
        parts = [p.strip() for p in line.replace("info string", "").split("|")]
        if len(parts) >= 4:
            name = parts[0].strip().lower().replace(" ", "_")
            try:
                w = float(parts[1])
                b = float(parts[2])
                t = float(parts[3])
                if name:
                    terms[name] = {"white": w, "black": b, "total": t}
            except ValueError:
                pass
        if "final" in line.lower() or (in_table and not line.strip()):
            break
    return terms if terms else None


# ── UCI Engine ────────────────────────────────────────────────────────────────

class UCIEngine:
    """
    Wraps any UCI-compliant engine (lc0, Stockfish, Komodo, …) via subprocess.
    Each instance has its own asyncio.Lock so concurrent calls to *different*
    engines are fully parallel; calls to the *same* engine are serialised.
    """

    def __init__(
        self,
        exe_path:             str,
        weights_path:         Optional[str] = None,
        capture_info_strings: bool = False,
        name:                 str = "engine",
    ):
        self.exe_path             = exe_path
        self.weights_path         = weights_path
        self.capture_info_strings = capture_info_strings
        self.name                 = name
        self._proc:  Optional[subprocess.Popen] = None
        self._ready  = asyncio.Event()
        self._queue: asyncio.Queue = asyncio.Queue()
        self._loop:  Optional[asyncio.AbstractEventLoop] = None
        self._lock   = asyncio.Lock()   # serialise calls to this engine

    def start(self, loop: asyncio.AbstractEventLoop):
        self._loop = loop
        cmd = [self.exe_path]
        if self.weights_path:
            cmd.append(f"--weights={self.weights_path}")
        log.info("[%s] Launching: %s", self.name, " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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
            log.info("[%s] stopped.", self.name)

    def _send(self, line: str):
        if self._proc and self._proc.stdin:
            self._proc.stdin.write(line + "\n")
            self._proc.stdin.flush()
            log.debug("[%s] → %s", self.name, line)

    def _reader(self):
        for raw in iter(self._proc.stdout.readline, ""):
            line = raw.rstrip()
            if not line:
                continue
            log.debug("[%s] ← %s", self.name, line)
            if line == "uciok":
                self._loop.call_soon_threadsafe(self._ready.set)
            self._loop.call_soon_threadsafe(self._queue.put_nowait, line)
        log.warning("[%s] stdout closed", self.name)

    async def wait_ready(self):
        await self._ready.wait()
        self._send("isready")
        while True:
            line = await self._queue.get()
            if line == "readyok":
                log.info("[%s] ready", self.name)
                return

    def new_game(self):
        self._send("ucinewgame")

    def set_option(self, name: str, value: str):
        self._send(f"setoption name {name} value {value}")

    # ── Public analysis API ──────────────────────────────────────────────────

    async def get_engine_move(self, fen: str, movetime_ms: int = 3000) -> dict:
        """
        Return just the best move with basic eval.
        FIX: now includes 'from', 'to', 'promotion' fields required by UCIRobot.
        """
        result   = await self.analyse(fen, movetime_ms)
        bestmove = result.get("bestmove")
        from_sq, to_sq, promotion = uci_to_parts(bestmove) if bestmove else ("", "", None)
        return {
            "type":       "engine_move",
            "move":       bestmove,
            "from":       from_sq,
            "to":         to_sq,
            "promotion":  promotion,
            "score_cp":   result.get("score_cp"),
            "score_mate": result.get("score_mate"),
            "pv":         result.get("pv", []),
        }

    async def analyse(self, fen: str, movetime_ms: int = 2000, deep: bool = False) -> dict:
        """
        Run a full MultiPV analysis. Caller MUST hold self._lock.
        deep=True enables analysis-mode metrics (pawn structure, king safety).
        """
        while not self._queue.empty():
            self._queue.get_nowait()

        self._send(f"position fen {fen}")
        self._send(f"go movetime {movetime_ms}")

        mpv:         dict[int, dict] = {}
        best_depth   = 0
        best_nodes   = 0
        timeout      = (movetime_ms / 1000.0) + 15.0
        depth_evals: list[int] = []
        final_wdl:   Optional[tuple[int, int, int]] = None
        info_strings: list[str] = []

        while True:
            try:
                line = await asyncio.wait_for(self._queue.get(), timeout=timeout)
            except asyncio.TimeoutError:
                log.error("[%s] timeout waiting for bestmove (fen=%s)", self.name, fen)
                self._send("stop")
                raise

            if line.startswith("info string"):
                if self.capture_info_strings:
                    info_strings.append(line)

            elif line.startswith("info"):
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

                slot1 = mpv.get(1, {})
                if slot1.get("score_cp") is not None:
                    depth_evals.append(slot1["score_cp"])
                if slot1.get("wdl") is not None:
                    final_wdl = slot1["wdl"]

            elif line.startswith("bestmove"):
                score_drift = self._compute_score_drift(depth_evals)
                nnue = parse_stockfish_eval(info_strings) if info_strings else None
                return self._build_result(
                    line, mpv, best_depth, best_nodes,
                    score_drift, final_wdl, fen,
                    nnue=nnue, deep=deep
                )

    # ── Parsing helpers ──────────────────────────────────────────────────────

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
                "pv": [], "move": None, "wdl": None,
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

            if "wdl" in parts:
                wi = parts.index("wdl")
                w  = int(parts[wi + 1])
                d  = int(parts[wi + 2])
                l  = int(parts[wi + 3])
                mpv[slot]["wdl"] = (w, d, l)

            if "pv" in parts:
                pi = parts.index("pv")
                pv = parts[pi + 1:]
                mpv[slot]["pv"]   = pv
                mpv[slot]["move"] = pv[0] if pv else None
        except (ValueError, IndexError):
            pass

    def _compute_score_drift(self, depth_evals: list[int]) -> int:
        if len(depth_evals) < 2:
            return 0
        final = depth_evals[-1]
        return max(abs(e - final) for e in depth_evals)

    def _build_result(
        self,
        bestmove_line: str,
        mpv:           dict,
        depth:         int,
        nodes:         int,
        score_drift:   int,
        final_wdl:     Optional[tuple],
        fen:           str,
        nnue:          Optional[dict],
        deep:          bool = False,
    ) -> dict:
        parts    = bestmove_line.split()
        bestmove = parts[1] if len(parts) > 1 else None
        if bestmove == "(none)":
            bestmove = None

        # FIX: split bestmove into from/to/promotion for Swift UCIRobot
        from_sq, to_sq, promotion = uci_to_parts(bestmove) if bestmove else ("", "", None)

        slot1 = mpv.get(1, {})

        # FIX: was enumerate(range(2, MULTI_PV+1), start=2) — rank always equalled s
        alternatives = []
        for s in range(2, MULTI_PV + 1):
            sl = mpv.get(s, {})
            if sl.get("move"):
                from_a, to_a, promo_a = uci_to_parts(sl["move"])
                alternatives.append({
                    "rank":       s,
                    "move":       sl["move"],
                    "from":       from_a,
                    "to":         to_a,
                    "promotion":  promo_a,
                    "score_cp":   sl.get("score_cp"),
                    "score_mate": sl.get("score_mate"),
                    "pv":         sl.get("pv", [])[:5],
                })

        wdl_out = None
        if final_wdl is not None:
            w, d, l = final_wdl
            total   = w + d + l or 1
            wdl_out = {
                "white": round(w / total, 4),
                "draw":  round(d / total, 4),
                "black": round(l / total, 4),
            }

        # ── Always computed (cheap python-chess arithmetic) ─────────────────
        fen_parts    = fen.split()
        side_to_move = fen_parts[1] if len(fen_parts) > 1 else "w"

        metrics  = compute_position_metrics(fen)
        phase    = game_phase(fen)
        feedback = score_to_feedback(slot1.get("score_cp"), slot1.get("score_mate"), side_to_move)

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

        # ── Analysis-mode only (deeper python-chess work) ────────────────────
        pawn_info  = {}
        king_info  = {}
        if deep:
            pawn_info = pawn_structure(fen)
            king_info = king_safety(fen)

        return {
            # ── Core (both modes) ────────────────────────────────────────────
            "type":             "analysis",
            "fen":              fen,
            "bestmove":         bestmove,
            "from":             from_sq,
            "to":               to_sq,
            "promotion":        promotion,
            "score_cp":         slot1.get("score_cp"),
            "score_mate":       slot1.get("score_mate"),
            "pv":               slot1.get("pv", []),
            "depth":            depth,
            "nodes":            nodes,
            "score_drift":      score_drift,
            "wdl":              wdl_out,
            "feedback":         feedback,
            "alternatives":     alternatives,
            "characteristics":  chars,
            # python-chess metrics (free)
            "material_balance": metrics["material_balance"],
            "mobility_white":   metrics["mobility_white"],
            "mobility_black":   metrics["mobility_black"],
            "game_phase":       phase,
            # ── Analysis mode only ───────────────────────────────────────────
            "nnue":             nnue,        # Stockfish NNUE term breakdown
            # Pawn structure
            "isolated_white":   pawn_info.get("isolated_white"),
            "isolated_black":   pawn_info.get("isolated_black"),
            "doubled_white":    pawn_info.get("doubled_white"),
            "doubled_black":    pawn_info.get("doubled_black"),
            "passed_white":     pawn_info.get("passed_white"),
            "passed_black":     pawn_info.get("passed_black"),
            "pawn_structure":   pawn_info.get("structure"),
            # King safety
            "king_attackers_white": king_info.get("king_attackers_white"),
            "king_attackers_black": king_info.get("king_attackers_black"),
            "king_castled_white":   king_info.get("king_castled_white"),
            "king_castled_black":   king_info.get("king_castled_black"),
        }


# ── WebSocket Server ──────────────────────────────────────────────────────────

class ChessServer:
    def __init__(self, engines: dict[str, UCIEngine], primary: str, host: str, port: int):
        self.engines = engines
        self.primary = primary
        self.host    = host
        self.port    = port
        self.clients: set = set()  # FIX: was self._clients (name mismatch)

    async def handle(self, ws):
        # FIX: was self._clients (crashed on every connection)
        self.clients.add(ws)
        log.info("Client connected: %s", ws.remote_address)
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await ws.send(json.dumps({"type": "error", "message": "Invalid JSON"}))
                    continue
                # FIX: was `await self._dispatch(ws, msg)` — ws param was spurious
                # and the return value was never sent back to the client
                result = await self._dispatch(msg)
                await ws.send(json.dumps(result))
        except websockets.exceptions.ConnectionClosed:
            log.info("Client disconnected: %s", ws.remote_address)
        finally:
            self.clients.discard(ws)

    async def _dispatch(self, data: dict) -> dict:
        # FIX: signature was `(self, data)` — ws param listed in call but not in def
        cmd = data.get("cmd")

        if cmd == "ping":
            return {"type": "pong"}

        # `engines` — advertise available engine names to the client.
        # Called once on connect so the Swift UI can build live pickers
        # instead of relying on hardcoded strings.
        if cmd == "engines":
            return {
                "type":    "engines",
                "engines": list(self.engines.keys()),
                "primary": self.primary,
            }

        # FIX: new_game was unhandled — server silently returned "Unknown command"
        if cmd == "new_game":
            for engine in self.engines.values():
                engine.new_game()
            return {"type": "ok"}

        # Resolve the requested engine; fall back to primary
        engine_id = data.get("engine", self.primary)
        engine = self.engines.get(engine_id) or self.engines.get(self.primary)
        if engine is None:
            return {
                "type":    "error",
                "message": f"Engine '{engine_id}' not found. "
                           f"Available: {list(self.engines.keys())}",
            }

        if cmd == "analyse":
            fen      = data.get("fen", "")
            movetime = int(data.get("movetime", 2000))
            deep     = bool(data.get("deep", False))

            eval_id = data.get("eval_engine", self.primary)
            move_id = data.get("best_move_engine", self.primary)
            nnue_id = data.get("nnue_engine", "")   # only meaningful when deep=True

            eval_eng = self.engines.get(eval_id) or self.engines.get(self.primary)
            move_eng = self.engines.get(move_id) or self.engines.get(self.primary)

            if eval_eng is None:
                return {"type": "error", "message": f"eval_engine '{eval_id}' not found."}

            # ── In analysis mode, run the primary eval engine AND the NNUE engine
            # concurrently. The NNUE engine (typically Stockfish) is registered with
            # capture_info_strings=True, so its analyse() call returns a populated
            # `nnue` dict. We merge that into the primary result before sending.
            # In regular play mode (deep=False) only the primary engine runs.

            nnue_eng = None
            if deep and nnue_id and nnue_id != eval_id:
                nnue_eng = self.engines.get(nnue_id)
                if nnue_eng is None:
                    log.warning("nnue_engine '%s' not found — NNUE analysis skipped", nnue_id)

            if nnue_eng is not None:
                # Run both engines concurrently
                async def _run_eval():
                    async with eval_eng._lock:
                        return await eval_eng.analyse(fen, movetime, deep=deep)

                async def _run_nnue():
                    async with nnue_eng._lock:
                        return await nnue_eng.analyse(fen, movetime)

                result, nnue_result = await asyncio.gather(_run_eval(), _run_nnue())
                result["nnue"] = nnue_result.get("nnue")
            else:
                async with eval_eng._lock:
                    result = await eval_eng.analyse(fen, movetime, deep=deep)

            deep_score_cp = None
            if move_eng is not eval_eng:
                async with move_eng._lock:
                    move_result = await move_eng.get_engine_move(fen, movetime)
                result["bestmove"]  = move_result.get("move")
                result["from"]      = move_result.get("from", "")
                result["to"]        = move_result.get("to", "")
                result["promotion"] = move_result.get("promotion")
                deep_score_cp       = move_result.get("score_cp")

            result["deep_score_cp"] = deep_score_cp
            return result

        elif cmd == "engine_move":
            fen      = data.get("fen", "")
            movetime = int(data.get("movetime", 3000))
            async with engine._lock:
                return await engine.get_engine_move(fen, movetime)

        return {"type": "error", "message": f"Unknown command: {cmd}"}

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


# ── Argument parsing ──────────────────────────────────────────────────────────

def parse_engine_spec(spec: str) -> tuple[str, str, Optional[str]]:
    """
    Parse 'NAME=EXE[:WEIGHTS]' into (name, exe_path, weights_path_or_None).

    Examples:
      lc0=lc0/lc0.exe:lc0/BT4-332.pb  → ('lc0', 'lc0/lc0.exe', 'lc0/BT4-332.pb')
      stockfish=sf/stockfish.exe        → ('stockfish', 'sf/stockfish.exe', None)
    """
    if "=" not in spec:
        raise ValueError(
            f"Invalid engine spec '{spec}': expected NAME=EXE or NAME=EXE:WEIGHTS"
        )
    name, rest = spec.split("=", 1)
    if ":" in rest:
        exe, weights = rest.split(":", 1)
    else:
        exe, weights = rest, None
    return name.strip(), exe.strip(), (weights.strip() if weights else None)


def parse_args():
    p = argparse.ArgumentParser(
        description="Model-Agnostic UCI WebSocket Bridge",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--engine", action="append", dest="engines", default=[],
        metavar="NAME=EXE[:WEIGHTS]",
        help="Register an engine. Repeat for each engine. "
             "Format: name=path/to/exe[:path/to/weights]",
    )
    p.add_argument(
        "--primary", default="",
        help="Engine name to use as the 'primary' alias (defaults to first --engine)",
    )
    p.add_argument("--port",    type=int, default=8765,    help="WebSocket port")
    p.add_argument("--host",    default="0.0.0.0",         help="Bind address")
    p.add_argument("--threads", type=int, default=4,       help="UCI Threads sent to every engine")
    return p.parse_args()


# ── Entry Point ───────────────────────────────────────────────────────────────

async def main():
    args = parse_args()

    if not args.engines:
        log.error("No engines configured. Use --engine NAME=EXE[:WEIGHTS]")
        sys.exit(1)

    # Parse engine specs and build dict
    engines: dict[str, UCIEngine] = {}
    loop = asyncio.get_running_loop()

    for spec in args.engines:
        try:
            name, exe, weights = parse_engine_spec(spec)
        except ValueError as e:
            log.error("%s", e)
            sys.exit(1)

        exe_abs     = os.path.abspath(exe)
        weights_abs = os.path.abspath(weights) if weights else None

        log.info("Engine %-16s exe=%s (exists=%s)", f"'{name}':", exe_abs, os.path.exists(exe_abs))
        if weights_abs:
            log.info("  weights: %s (exists=%s)", weights_abs, os.path.exists(weights_abs))

        # Enable info-string capture for engines that produce NNUE output (Stockfish)
        capture_nnue = (weights_abs is None)   # heuristic: weightless engines → Stockfish-like

        eng = UCIEngine(
            exe_path             = exe_abs,
            weights_path         = weights_abs,
            capture_info_strings = capture_nnue,
            name                 = name,
        )
        eng.start(loop)
        engines[name] = eng

    # Resolve primary
    primary = args.primary or next(iter(engines))
    if primary not in engines:
        log.error("--primary '%s' is not a registered engine name", primary)
        sys.exit(1)
    log.info("Primary engine: '%s'", primary)
    log.info("Port: %d | Threads: %d | python-chess: %s",
             args.port, args.threads,
             "available" if HAS_CHESS else "NOT INSTALLED — pip install python-chess")

    # UCI handshake for all engines
    for name, eng in engines.items():
        log.info("Waiting for UCI handshake: %s …", name)
        await eng.wait_ready()
        eng.set_option("Threads", str(args.threads))
        eng.set_option("MultiPV", str(MULTI_PV))
        if eng.capture_info_strings:
            # Stockfish-like engine: enable NNUE eval output and WDL display.
            # UCI_ShowWDL (Stockfish 15.1+) outputs empirically calibrated W/D/L
            # probabilities — more useful for training than lc0's self-play WDL.
            eng.set_option("Use NNUE", "true")
            eng.set_option("UCI_ShowWDL", "true")
        log.info("Engine '%s' ready", name)

    threading.Thread(
        target=_stdin_quit_watcher, args=(loop,), daemon=True
    ).start()

    # FIX: was Lc0Server(engine, ...) — passed a single UCIEngine not the dict,
    # and had an extra stockfish= kwarg the constructor didn't accept
    server = ChessServer(engines=engines, primary=primary, host=args.host, port=args.port)
    try:
        await server.run()
    except (KeyboardInterrupt, asyncio.CancelledError):
        log.info("Shutting down…")
    finally:
        for eng in engines.values():
            eng.stop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Stopped by Ctrl+C.")