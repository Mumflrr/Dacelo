// Lc0Robot.swift
// Dacelo

import Chess
import Foundation

// MARK: - RobotController
//
// Thread-safe controller shared between GameStore (MainActor) and Lc0Robot
// (background thread). Replaces the old PausedFlag with a richer interface
// that also supports depositing a manual move so the human can play for Leela.

final class RobotController: @unchecked Sendable {
    private let lock = NSLock()
    private var _isPaused    = false
    private var _isCancelled = false
    private var _manualMove: (from: Int, to: Int)? = nil

    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }

    var isCancelled: Bool {
        get { lock.withLock { _isCancelled } }
        set { lock.withLock { _isCancelled = newValue } }
    }

    /// Called from the UI when the user plays a move on behalf of Leela.
    func submitManualMove(from: Int, to: Int) {
        lock.withLock { _manualMove = (from: from, to: to) }
    }

    /// Called from the robot thread to consume a pending manual move.
    func takeManualMove() -> (from: Int, to: Int)? {
        lock.withLock {
            let m = _manualMove
            _manualMove = nil
            return m
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

// MARK: - Lc0Robot

final class Lc0Robot: Chess.Robot {

    private let engine: EngineService
    private let moveTimeMs: Int
    weak var robotController: RobotController?
    private var isEvaluating = false  // add as instance property

    init(side: Chess.Side,
         engine: EngineService,
         moveTimeMs: Int = 3000,
         robotController: RobotController? = nil) {
        self.engine          = engine
        self.moveTimeMs      = moveTimeMs
        self.robotController = robotController
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot

    override func evalutate(board: Chess.Board) -> Chess.Move? {
// In case we need to lock the evaluation to prevent multiple evals being sent rapidly
//        guard !isEvaluating else {
//                Thread.sleep(forTimeInterval: 0.5)
//                return nil
//        }
//        isEvaluating = true
//        defer { isEvaluating = false }
//        
        guard let controller = robotController else { return nil }
        guard !controller.isCancelled else { return nil }

        // If paused before thinking starts, wait for a manual move or resume.
        if controller.isPaused {
            if let move = waitForManualMoveOrResume(controller: controller) {
                return move
            }
            // Returned nil means we were resumed — fall through to engine.
            guard !controller.isCancelled else { return nil }
        }

        let fen       = board.FEN
        let semaphore = DispatchSemaphore(value: 0)
        let box       = MoveBox()

        Task {
            defer { semaphore.signal() }
            do {
                let response = try await engine.engineMove(fen: fen, movetime: moveTimeMs)
                guard let fromStr = response.from, let toStr = response.to else {
                    print("[Lc0Robot] Missing from/to in response"); return
                }
                print("[Lc0Robot] Playing \(fromStr)-\(toStr)")
                let sideEffect: Chess.Move.SideEffect
                if let promo = response.promotion, let piece = promotionPiece(promo) {
                    sideEffect = .promotion(piece: piece)
                } else {
                    sideEffect = .notKnown
                }
                box.move = Chess.Move(
                    side:       side,
                    start:      Chess.Position.from(rankAndFile: fromStr),
                    end:        Chess.Position.from(rankAndFile: toStr),
                    sideEffect: sideEffect
                )
            } catch {
                print("[Lc0Robot] Error: \(error.localizedDescription)")
            }
        }

        let deadline = DispatchTime.now() + .milliseconds(moveTimeMs + 10_000)
        if semaphore.wait(timeout: deadline) == .timedOut {
            print("[Lc0Robot] Timed out waiting for engine")
        }

        guard !controller.isCancelled else { return nil }

        // If paused while the engine was thinking, wait for manual move or resume.
        // The engine result is discarded in favour of the manual move.
        if controller.isPaused {
            if let move = waitForManualMoveOrResume(controller: controller) {
                return move
            }
            guard !controller.isCancelled else { return nil }
        }

        return box.move
    }

    // MARK: - Manual move / pause wait

    /// Spins until either a manual move is submitted or the controller is resumed.
    /// Returns the manual Chess.Move if one was submitted, nil if we were simply resumed.
    private func waitForManualMoveOrResume(controller: RobotController) -> Chess.Move? {
        while controller.isPaused && !controller.isCancelled {
            if let manual = controller.takeManualMove() {
                return Chess.Move(
                    side:       side,
                    start:      Chess.Position(manual.from),
                    end:        Chess.Position(manual.to),
                    sideEffect: .notKnown
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    // MARK: - Helpers

    private func promotionPiece(_ uci: String) -> Chess.PieceType? {
        switch uci.lowercased() {
        case "q": return .queen
        case "r": return .rook
        case "b": return .bishop
        case "n": return .knight
        default:  return nil
        }
    }
}

private final class MoveBox: @unchecked Sendable {
    var move: Chess.Move?
}
