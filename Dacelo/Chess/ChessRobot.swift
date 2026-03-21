// ChessRobot.swift
// Dacelo
//
// Replaces UCIRobot.swift. No longer subclasses Chess.Robot —
// instead runs as a simple async loop controlled by GameStore.
//
// Architecture:
//   GameStore owns a ChessRobot instance.
//   When it's the robot's turn, GameStore calls think(board:).
//   think() is an async function — it awaits the engine response
//   and returns the move. GameStore applies it via ChessGame.applyRobotMove.
//
// Pause / manual override:
//   RobotController is unchanged — GameStore sets isPaused, the user
//   submits manual moves via submitManualMove(from:to:).
//   think() checks the controller the same way UCIRobot.evaluate() did,
//   but without the semaphore/DispatchSemaphore pattern — we use
//   async/await properly throughout.

import Foundation

// MARK: - RobotController (unchanged public API, cleaner internals)

final class RobotController: @unchecked Sendable {
    private let lock                        = NSLock()
    private var _isPaused:    Bool          = false
    private var _isCancelled: Bool          = false
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
        lock.withLock {
            defer { _manualMove = nil }
            return _manualMove
        }
    }

    func reset() {
        lock.withLock {
            _isPaused    = false
            _isCancelled = false
            _manualMove  = nil
        }
    }
}

// MARK: - ChessRobot

/// Async robot that requests moves from EngineService and delivers
/// them back to GameStore via a callback.
actor ChessRobot {

    // MARK: Configuration

    let side:            Side
    let engine:          EngineService
    let moveTimeMs:      Int
    let bestMoveEngine:  String

    // MARK: State

    // nonisolated because RobotController is already thread-safe via NSLock,
    // and GameStore (@MainActor) needs to set isPaused without await.
    nonisolated let controller: RobotController
    private var thinkTask: Task<Void, Never>? = nil

    // MARK: Init

    init(
        side:           Side,
        engine:         EngineService,
        moveTimeMs:     Int    = 3000,
        bestMoveEngine: String = "primary"
    ) {
        self.side           = side
        self.engine         = engine
        self.moveTimeMs     = moveTimeMs
        self.bestMoveEngine = bestMoveEngine
        self.controller     = RobotController()
    }

    // MARK: - Think

    /// Request a move for the given board position. Returns (from, to, promotion)
    /// or nil if cancelled/failed.
    ///
    /// This replaces the old semaphore-blocking evaluate() method.
    /// It's a clean async function — no DispatchSemaphore, no Thread.sleep.
    func think(board: ChessBoard) async -> (from: BoardIndex, to: BoardIndex, promotion: PieceType?)? {

        // Check cancellation before starting.
        guard !controller.isCancelled else { return nil }

        // If paused, wait for unpause or manual move.
        if controller.isPaused {
            if let manual = await waitForManualOrResume() { return manual }
            guard !controller.isCancelled else { return nil }
        }

        let fen = board.fen

        do {
            let response = try await engine.engineMove(
                fen:            fen,
                movetime:       moveTimeMs,
                bestMoveEngine: bestMoveEngine
            )

            guard !controller.isCancelled else { return nil }

            guard let fromStr = response.from, let toStr = response.to else {
                print("[ChessRobot:\(bestMoveEngine)] Missing from/to in response")
                return nil
            }

            guard let from = BoardIndex.from(algebraic: fromStr),
                  let to   = BoardIndex.from(algebraic: toStr) else {
                print("[ChessRobot:\(bestMoveEngine)] Invalid squares: \(fromStr)-\(toStr)")
                return nil
            }

            let promotion: PieceType? = response.promotion.flatMap { PieceType(rawValue: $0.lowercased()) }

            print("[ChessRobot:\(bestMoveEngine)] Playing \(fromStr)-\(toStr)")

            // Check pause again after engine response (user may have paused during think).
            if controller.isPaused {
                if let manual = await waitForManualOrResume() { return manual }
                guard !controller.isCancelled else { return nil }
            }

            return (from: from, to: to, promotion: promotion)

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
            // Yield to the cooperative thread pool — no Thread.sleep.
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
        return nil
    }
}
