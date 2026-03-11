// Lc0Robot.swift
// Dacelo
//
// Chess.Robot subclass. Now that EngineService is a Swift actor,
// evalutate() can simply spin up a Task and block the library's
// detached thread with a semaphore — but the Task itself just
// `await`s on the actor with no @MainActor involvement, so there
// is no deadlock with ChessStore.gameSemaphore.

import Chess
import Foundation

final class Lc0Robot: Chess.Robot {

    private let engine: EngineService
    private let moveTimeMs: Int

    init(side: Chess.Side, engine: EngineService, moveTimeMs: Int = 3000) {
        self.engine      = engine
        self.moveTimeMs  = moveTimeMs
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot

    override func evalutate(board: Chess.Board) -> Chess.Move? {
        let fen       = board.FEN
        let semaphore = DispatchSemaphore(value: 0)
        let box       = MoveBox()

        Task {
            defer { semaphore.signal() }
            do {
                let response = try await engine.engineMove(fen: fen, movetime: moveTimeMs)

                guard let fromStr = response.from,
                      let toStr   = response.to else {
                    print("[Lc0Robot] Missing from/to in response")
                    return
                }

                print("[Lc0Robot] Playing \(fromStr)-\(toStr)")

                let sideEffect: Chess.Move.SideEffect
                if let promo = response.promotion,
                   let piece = promotionPiece(promo) {
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

        // Block the library's detached thread.
        // EngineService is a background actor — the Task above never
        // touches MainActor, so ChessStore.gameSemaphore is not involved.
        let deadline = DispatchTime.now() + .milliseconds(moveTimeMs + 10_000)
        if semaphore.wait(timeout: deadline) == .timedOut {
            print("[Lc0Robot] Timed out waiting for engine")
        }
        return box.move
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

// Reference-type box avoids "mutation of captured var" error
private final class MoveBox: @unchecked Sendable {
    var move: Chess.Move?
}
