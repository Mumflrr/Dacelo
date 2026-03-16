// UCIRobot.swift
// Dacelo
//
// Engine-agnostic Chess.Robot implementation.
// Communicates with whatever engine the server has registered as the
// bestMoveEngine — defaults to "primary" but can be any name the server
// advertises (e.g. "deep", "komodo", etc.).

import Chess
import Foundation

// MARK: - RobotController
//
// Thread-safe controller shared between GameStore (MainActor) and UCIRobot
// (background thread). Handles pause, cancel, and manual move submission
// so the user can play moves on the engine's behalf when paused.

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

    func submitManualMove(from: Int, to: Int) {
        lock.withLock { _manualMove = (from: from, to: to) }
    }

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

// MARK: - UCIRobot

final class UCIRobot: Chess.Robot {

    private let engine:          EngineService
    private let moveTimeMs:      Int
    /// Server-side engine name to use for move generation (e.g. "primary", "deep").
    private let bestMoveEngine:  String
    weak var robotController:    RobotController?

    init(
        side:            Chess.Side,
        engine:          EngineService,
        moveTimeMs:      Int             = 3000,
        bestMoveEngine:  String          = "primary",
        robotController: RobotController? = nil
    ) {
        self.engine          = engine
        self.moveTimeMs      = moveTimeMs
        self.bestMoveEngine  = bestMoveEngine
        self.robotController = robotController
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot

    override func evalutate(board: Chess.Board) -> Chess.Move? {
        guard let controller = robotController else { return nil }
        guard !controller.isCancelled else { return nil }

        if controller.isPaused {
            if let move = waitForManualMoveOrResume(controller: controller) { return move }
            guard !controller.isCancelled else { return nil }
        }

        let fen       = board.FEN
        let semaphore = DispatchSemaphore(value: 0)
        let box       = MoveBox()

        Task {
            defer { semaphore.signal() }
            do {
                let response = try await engine.engineMove(
                    fen:            fen,
                    movetime:       moveTimeMs,
                    bestMoveEngine: bestMoveEngine
                )
                guard let fromStr = response.from, let toStr = response.to else {
                    print("[UCIRobot:\(bestMoveEngine)] Missing from/to in response"); return
                }
                print("[UCIRobot:\(bestMoveEngine)] Playing \(fromStr)-\(toStr)")
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
                print("[UCIRobot:\(bestMoveEngine)] Error: \(error.localizedDescription)")
            }
        }

        let deadline = DispatchTime.now() + .milliseconds(moveTimeMs + 10_000)
        if semaphore.wait(timeout: deadline) == .timedOut {
            print("[UCIRobot:\(bestMoveEngine)] Timed out waiting for engine")
        }

        guard !controller.isCancelled else { return nil }

        if controller.isPaused {
            if let move = waitForManualMoveOrResume(controller: controller) { return move }
            guard !controller.isCancelled else { return nil }
        }

        return box.move
    }

    // MARK: - Pause / manual move

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
