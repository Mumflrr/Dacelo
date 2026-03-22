// ChessRobot.swift
// Dacelo
//
// Async robot that requests moves from EngineService and applies a
// difficulty filter before returning the chosen move.
//
// ── Difficulty model ──────────────────────────────────────────────────────────
//
// difficulty: 0.0 (complete beginner) → 1.0 (full engine strength)
//
// Three mechanisms combine to produce human-like imperfection:
//
// 1. Opening randomisation (first N moves)
//    - difficulty 1.0 → always play engine's best move
//    - difficulty 0.0 → always play a random legal move
//    - In between: play engine move with probability = difficulty
//    This mimics humans who know theory well at high level, improvise at low.
//
// 2. Score threshold acceptance (middlegame / endgame)
//    Only moves within `acceptanceThreshold` centipawns of the best are
//    considered "acceptable". The threshold widens as difficulty drops:
//      difficulty 1.0 → threshold = 10cp  (only the best move)
//      difficulty 0.5 → threshold = 150cp (many moves qualify)
//      difficulty 0.0 → threshold = 400cp (almost any move)
//    This prevents obvious blunders at medium difficulty (threshold acceptance)
//    while still allowing suboptimal play.
//
// 3. Weighted random sampling (from acceptable moves)
//    Acceptable moves are weighted by a softmax over their scores.
//    The temperature of the softmax controls how random the sampling is:
//      difficulty 1.0 → temperature = 5cp   (best move overwhelmingly likely)
//      difficulty 0.5 → temperature = 100cp (reasonable spread)
//      difficulty 0.0 → temperature = 300cp (nearly uniform)
//    This makes lower-difficulty play non-deterministic — the robot doesn't
//    always play the same "second-best" move, it picks unpredictably from a
//    range of plausible-but-weaker alternatives.
//
// ── Why think time ≠ difficulty ──────────────────────────────────────────────
//
// Engine strength is determined by depth, not time.  On fast hardware a 3-second
// think reaches depth 20+.  Halving think time only drops 2-3 depth levels, which
// makes the engine marginally weaker but still plays nearly perfectly.
// The sampling approach above is what actually makes the engine play like a human
// at a given skill level, regardless of hardware speed.

import Foundation

// MARK: - DifficultyProfile

/// Pre-computed parameters for a given difficulty level.
/// Computed once per game so the values are consistent throughout.
struct DifficultyProfile {
    let difficulty:          Double   // 0.0–1.0
    let acceptanceThreshold: Int      // centipawns — max cp loss vs best to be "acceptable"
    let temperature:         Double   // softmax temperature in centipawns
    let openingMoves:        Int      // how many moves the opening phase lasts
    let openingBookProb:     Double   // probability of playing engine's best in opening

    init(difficulty: Double, openingMoves: Int = 8) {
        // Clamp to valid range
        let d = max(0.0, min(1.0, difficulty))
        self.difficulty      = d
        self.openingMoves    = openingMoves
        self.openingBookProb = d  // simple linear: 100% at max, 0% at min

        // Threshold: lerp 400cp (easy) → 10cp (hard)
        // At d=0.5: threshold = 205cp — move must be within 2 pawns of best
        self.acceptanceThreshold = Int((1.0 - d) * 390 + 10)

        // Temperature: lerp 300cp (easy) → 5cp (hard)
        // Higher temperature = more uniform distribution = more random
        self.temperature = (1.0 - d) * 295 + 5
    }

    /// Human-readable label for display in Settings
    var label: String {
        switch difficulty {
        case 0.0..<0.2:  return "Beginner"
        case 0.2..<0.4:  return "Novice"
        case 0.4..<0.6:  return "Intermediate"
        case 0.6..<0.8:  return "Advanced"
        case 0.8..<0.95: return "Expert"
        default:          return "Engine"
        }
    }
}

// MARK: - RobotController

final class RobotController: @unchecked Sendable {
    private let lock                         = NSLock()
    private var _isPaused:    Bool           = false
    private var _isCancelled: Bool           = false
    private var _manualMove: (from: Int, to: Int)? = nil

    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }
    var isCancelled: Bool {
        get { lock.withLock { _isCancelled } }
        set { lock.withLock { _isCancelled = newValue } }
    }
    func submitManualMove(from: Int, to: Int) {
        lock.withLock { _manualMove = (from, to) }
    }
    func takeManualMove() -> (from: Int, to: Int)? {
        lock.withLock { defer { _manualMove = nil }; return _manualMove }
    }
    func reset() {
        lock.withLock { _isPaused = false; _isCancelled = false; _manualMove = nil }
    }
}

// MARK: - Candidate move

private struct Candidate {
    let from:      BoardIndex
    let to:        BoardIndex
    let promotion: PieceType?
    let scoreCP:   Int          // normalised to side-to-move positive
}

// MARK: - ChessRobot

actor ChessRobot {

    // MARK: Configuration

    let side:           Side
    let engine:         EngineService
    let moveTimeMs:     Int
    let bestMoveEngine: String
    let profile:        DifficultyProfile

    // MARK: State

    nonisolated let controller: RobotController
    private var thinkTask: Task<Void, Never>? = nil
    private var moveCount: Int = 0

    // Ponder candidates set after each think(). GameStore reads these from
    // @MainActor immediately after the robot move is applied, so they need
    // to be nonisolated. Protected by the fact that GameStore only reads
    // them synchronously after the robot Task completes (via await MainActor.run).
    nonisolated(unsafe) private(set) var lastPonderFEN:  String? = nil
    nonisolated(unsafe) private(set) var lastPonderMove: String? = nil   // incremented after each move played

    // MARK: Init

    init(
        side:           Side,
        engine:         EngineService,
        moveTimeMs:     Int    = 3000,
        bestMoveEngine: String = "primary",
        difficulty:     Double = 1.0,
        openingMoves:   Int    = 8
    ) {
        self.side           = side
        self.engine         = engine
        self.moveTimeMs     = moveTimeMs
        self.bestMoveEngine = bestMoveEngine
        self.profile        = DifficultyProfile(difficulty: difficulty, openingMoves: openingMoves)
        self.controller     = RobotController()
    }

    // MARK: - Think

    /// Request a move for the given board position, filtered through the
    /// difficulty profile. Returns (from, to, promotion) or nil if cancelled.
    func think(board: ChessBoard) async -> (from: BoardIndex, to: BoardIndex, promotion: PieceType?)? {
        guard !controller.isCancelled else { return nil }

        if controller.isPaused {
            if let manual = await waitForManualOrResume() { return manual }
            guard !controller.isCancelled else { return nil }
        }

        // ── Opening phase: random legal move at low difficulty ────────────
        let isOpening = moveCount < profile.openingMoves
        if isOpening && profile.difficulty < 1.0 {
            if Double.random(in: 0..<1) > profile.openingBookProb {
                if let random = randomLegalMove(board: board) {
                    moveCount += 1
                    return random
                }
            }
        }

        // ── Engine request ────────────────────────────────────────────────
        do {
            let fen = board.fen

            // At full difficulty: use the fast engine_move path (no alternatives needed)
            if profile.difficulty >= 1.0 {
                let response = try await engine.engineMove(
                    fen:            fen,
                    movetime:       moveTimeMs,
                    bestMoveEngine: bestMoveEngine
                )
                guard !controller.isCancelled else { return nil }
                guard let fromStr = response.from, let toStr = response.to,
                      let from = BoardIndex.from(algebraic: fromStr),
                      let to   = BoardIndex.from(algebraic: toStr)
                else { return nil }
                let promotion = response.promotion.flatMap { PieceType(rawValue: $0.lowercased()) }
                // Store ponder candidate: PV[1] is the predicted human reply
                let pv = response.pv ?? []
                lastPonderFEN  = pv.count >= 2 ? fen : nil
                lastPonderMove = pv.count >= 2 ? pv[1] : nil
                moveCount += 1
                print("[ChessRobot:\(bestMoveEngine)] d=1.0 \(fromStr)→\(toStr)")
                return (from: from, to: to, promotion: promotion)
            }

            // Below full difficulty: use analyse() to get top-5 alternatives.
            // The server already runs MultiPV=5 by default (set at startup),
            // so this returns alternatives[] with scores for sampling.
            // evalEngine and bestMoveEngine both point to the robot's engine
            // so the server treats this identically to an engine_move request
            // but returns the full alternatives array.
            let result = try await engine.analyse(
                fen:            fen,
                movetime:       moveTimeMs,
                evalEngine:     bestMoveEngine,
                bestMoveEngine: bestMoveEngine
            )
            guard !controller.isCancelled else { return nil }

            guard let fromStr = result.from, let toStr = result.to,
                  let from = BoardIndex.from(algebraic: fromStr),
                  let to   = BoardIndex.from(algebraic: toStr)
            else {
                print("[ChessRobot:\(bestMoveEngine)] Missing/invalid from/to in analyse response")
                return nil
            }
            let promotion    = result.promotion.flatMap { PieceType(rawValue: $0.lowercased()) }
            let bestScoreCP  = result.score_cp ?? 0

            // ── Build candidate list ──────────────────────────────────────
            var candidates: [Candidate] = [
                Candidate(from: from, to: to, promotion: promotion, scoreCP: bestScoreCP)
            ]
            for alt in (result.alternatives ?? []) {
                guard let fromStr = alt.from, let toStr = alt.to,
                      let altFrom = BoardIndex.from(algebraic: fromStr),
                      let altTo   = BoardIndex.from(algebraic: toStr)
                else { continue }
                let altPromo = alt.promotion.flatMap { PieceType(rawValue: $0.lowercased()) }
                let altScore = alt.score_cp ?? (bestScoreCP - profile.acceptanceThreshold - 1)
                candidates.append(Candidate(from: altFrom, to: altTo,
                                            promotion: altPromo, scoreCP: altScore))
            }

            // ── Apply acceptance threshold ────────────────────────────────
            let threshold  = profile.acceptanceThreshold
            let acceptable = candidates.filter { bestScoreCP - $0.scoreCP <= threshold }
            let pool       = acceptable.isEmpty ? [candidates[0]] : acceptable

            // ── Weighted softmax sampling ─────────────────────────────────
            let chosen = softmaxSample(from: pool, temperature: profile.temperature)

            if controller.isPaused {
                if let manual = await waitForManualOrResume() { return manual }
                guard !controller.isCancelled else { return nil }
            }

            moveCount += 1
            let cpLoss = bestScoreCP - chosen.scoreCP
            print("[ChessRobot:\(bestMoveEngine)] d=\(String(format: "%.2f", profile.difficulty)) " +
                  "threshold=\(threshold)cp pool=\(pool.count)/\(candidates.count) cp_loss=\(cpLoss)")

            // Store ponder candidate: the FEN after this move + PV[1]
            // PV[0] is the move just played; PV[1] is the predicted human reply.
            let pv = result.pv ?? []
            if pv.count >= 2 {
                lastPonderFEN  = fen
                lastPonderMove = pv[1]  // predicted opponent reply
            } else {
                lastPonderFEN  = nil
                lastPonderMove = nil
            }

            return (from: chosen.from, to: chosen.to, promotion: chosen.promotion)

        } catch {
            print("[ChessRobot:\(bestMoveEngine)] Engine error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cancel

    func cancel() {
        controller.isCancelled = true
        thinkTask?.cancel()
        thinkTask = nil
    }

    // MARK: - Pause helpers

    private func waitForManualOrResume() async -> (from: BoardIndex, to: BoardIndex, promotion: PieceType?)? {
        while controller.isPaused && !controller.isCancelled {
            if let manual = controller.takeManualMove() {
                return (from: manual.from, to: manual.to, promotion: nil)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Move selection helpers

    /// Pick a random legal move for the current position.
    /// Used during the opening at low difficulty.
    private func randomLegalMove(board: ChessBoard) -> (from: BoardIndex, to: BoardIndex, promotion: PieceType?)? {
        let moves = ChessMoveGenerator.legalMoves(for: board)
        guard let move = moves.randomElement() else { return nil }
        return (from: move.from, to: move.to, promotion: move.promotion)
    }

    /// Softmax-weighted random sampling over candidates.
    /// weight(i) = exp((score_i - max_score) / temperature)
    /// High temperature → nearly uniform → random pick from pool.
    /// Low temperature  → best move dominates → nearly deterministic.
    private func softmaxSample(from candidates: [Candidate], temperature: Double) -> Candidate {
        guard candidates.count > 1 else { return candidates[0] }
        let maxScore = Double(candidates.map { $0.scoreCP }.max() ?? 0)
        let weights  = candidates.map { exp((Double($0.scoreCP) - maxScore) / temperature) }
        let total    = weights.reduce(0, +)
        var r = Double.random(in: 0..<total)
        for (candidate, weight) in zip(candidates, weights) {
            r -= weight
            if r <= 0 { return candidate }
        }
        return candidates.last!
    }

    // MARK: - Ponderhit path

    /// Called when the human played the predicted move — the engine has already
    /// been thinking on this position during the human's turn.
    /// Sends ponderhit and reads the result directly from EngineService.
    func thinkWithPonderHit(
        engine:         EngineService,
        bestMoveEngine: String,
        moveTimeMs:     Int
    ) async -> (from: BoardIndex, to: BoardIndex, promotion: PieceType?)? {
        guard !controller.isCancelled else { return nil }
        do {
            let response = try await engine.ponderhit(
                movetime:       moveTimeMs,
                bestMoveEngine: bestMoveEngine
            )
            guard !controller.isCancelled else { return nil }
            guard let fromStr = response.from, let toStr = response.to,
                  let from = BoardIndex.from(algebraic: fromStr),
                  let to   = BoardIndex.from(algebraic: toStr)
            else { return nil }
            let promotion = response.promotion.flatMap { PieceType(rawValue: $0.lowercased()) }
            let pv = response.pv ?? []
            lastPonderFEN  = pv.count >= 2 ? lastPonderFEN : nil
            lastPonderMove = pv.count >= 2 ? pv[1] : nil
            moveCount += 1
            print("[ChessRobot:\(bestMoveEngine)] ponderhit → \(fromStr)→\(toStr)")
            return (from: from, to: to, promotion: promotion)
        } catch {
            print("[ChessRobot:\(bestMoveEngine)] ponderhit failed: \(error.localizedDescription)")
            return nil
        }
    }
}
