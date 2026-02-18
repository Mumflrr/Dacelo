// Lc0Player.swift
// Dacelo
//
// Chess.Robot subclass that connects to remote lc0 server

import Chess
import Foundation

// MARK: - Lc0Robot

final class Lc0Robot: Chess.Robot {

    private let network: NetworkService
    private let moveTimeMs: Int
    weak var store: ChessStore?
    weak var analysisService: AnalysisService?

    init(side: Chess.Side, network: NetworkService, moveTimeMs: Int = 3000) {
        self.network    = network
        self.moveTimeMs = moveTimeMs
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot overrides

    override func evalutate(board: Chess.Board) -> Chess.Move? {
        let fen = board.FEN
        Task {
            await self.fetchAndDispatch(fen: fen, board: board)
        }
        return nil
    }

    // MARK: - Async move fetch

    @MainActor
    private func fetchAndDispatch(fen: String, board: Chess.Board) async {
        guard let store else {
            print("[Lc0Robot] No store reference")
            return
        }

        do {
            let response = try await network.engineMove(fen: fen, movetime: moveTimeMs)

            guard let fromStr = response.from,
                  let toStr   = response.to else {
                print("[Lc0Robot] Missing from/to in response")
                return
            }

            let startPos = Chess.Position.from(rankAndFile: fromStr)
            let endPos   = Chess.Position.from(rankAndFile: toStr)

            let sideEffect: Chess.Move.SideEffect
            if let promoStr  = response.promotion,
               let pieceType = promotionPieceType(from: promoStr) {
                sideEffect = .promotion(piece: pieceType)
            } else {
                sideEffect = .notKnown
            }

            let move = Chess.Move(
                side:       side,
                start:      startPos,
                end:        endPos,
                sideEffect: sideEffect
            )

            // Apply move — this triggers AppStore's setupMoveObserver which
            // calls analysis.recordMove() for this move automatically.
            store.gameAction(.makeMove(move: move))

        } catch {
            print("[Lc0Robot] Engine error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func promotionPieceType(from uciChar: String) -> Chess.PieceType? {
        switch uciChar.lowercased() {
        case "q": return .queen
        case "r": return .rook
        case "b": return .bishop
        case "n": return .knight
        default:  return nil
        }
    }
}
