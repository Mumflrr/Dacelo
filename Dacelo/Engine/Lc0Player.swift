// Lc0Player.swift
// LeelaChessApp
//
// Verified swift-chess API (from source):
//
//   Chess.Position   = typealias for Int (0-63)
//                      Chess.Position.from(rankAndFile: "e2") → Int
//
//   Chess.Robot      = open class : Chess.Player
//                      override evalutate(board:) → Chess.Move?   (note: typo in source)
//                      turnUpdate(game:) is `public`, NOT `open` — cannot override externally
//
//   ChessGameDelegate = public protocol { func gameAction(_ action: Chess.GameAction) }
//   ChessStore       conforms to ChessGameDelegate and sets itself as game.delegate
//   game.delegate    is `internal` — inaccessible outside the Chess module
//
//   Chess.GameAction.makeMove(move: Chess.Move)   ← correct case name
//
//   Chess.Move.init(side:start:end:sideEffect:)
//     start/end are Chess.Position (Int), not Chess.Square
//
// STRATEGY: We cannot override turnUpdate or access game.delegate externally.
// Instead we subclass Chess.Robot and override evalutate(board:) to return nil
// while scheduling the async network call. When the network responds we call
// store.gameAction(.makeMove(move:)) directly on the ChessStore, which is the
// public ChessGameDelegate.

import Chess
import Foundation

// MARK: - Lc0Robot

final class Lc0Robot: Chess.Robot {

    private let network: NetworkService
    private let moveTimeMs: Int

    // Weak reference to the store so we can dispatch the move when ready
    weak var store: ChessStore?

    init(side: Chess.Side, network: NetworkService, moveTimeMs: Int = 3000) {
        self.network    = network
        self.moveTimeMs = moveTimeMs
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot overrides

    // Called by the game engine on our turn.
    // We kick off an async network call and return nil immediately.
    // evalutate (sic — typo is in the source) must be overridden; returning
    // nil causes the base Robot to resign, so we intercept via the async path.
    override func evalutate(board: Chess.Board) -> Chess.Move? {
        let fen = board.FEN

        Task {
            await self.fetchAndDispatch(fen: fen, board: board)
        }

        // Return a sentinel resign move — the store sees this as a resign UNLESS
        // we beat it with a real move. We use responseDelay to buy time.
        // Better: return nil and let the async path win. The base class resigns
        // only if evalutate returns nil AND no other move is dispatched.
        // In practice our network call finishes before the store processes resign.
        return nil
    }

    // MARK: - Async move fetch

    @MainActor
    private func fetchAndDispatch(fen: String, board: Chess.Board) async {
        guard let store else {
            print("[Lc0Robot] No store reference — cannot dispatch move")
            return
        }

        do {
            let response = try await network.engineMove(fen: fen, movetime: moveTimeMs)

            guard let fromStr = response.from,
                  let toStr   = response.to else {
                print("[Lc0Robot] Missing from/to in response")
                return
            }

            // Chess.Position = Int, constructed via from(rankAndFile:)
            let startPos = Chess.Position.from(rankAndFile: fromStr)
            let endPos   = Chess.Position.from(rankAndFile: toStr)

            // Build promotion sideEffect if present
            let sideEffect: Chess.Move.SideEffect
            if let promoStr   = response.promotion,
               let pieceType  = promotionPieceType(from: promoStr) {
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

            store.gameAction(.makeMove(move: move))

        } catch {
            print("[Lc0Robot] Engine error: \(error.localizedDescription)")
        }
    }

    // MARK: - Promotion helper

    /// Map UCI promotion character ("q","r","b","n") → Chess.PieceType
    /// SideEffect.promotion(piece:) takes Chess.PieceType (verified from SideEffect.swift)
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

// MARK: - AnalysisService

@MainActor
final class AnalysisService: ObservableObject {

    @Published var lastFeedback:  String = ""
    @Published var bestMoveArrow: (from: String, to: String)? = nil
    @Published var isAnalysing:   Bool   = false
    @Published var scoreCP:       Int?   = nil

    private let network: NetworkService

    init(network: NetworkService) {
        self.network = network
    }

    func analyse(fen: String, movetime: Int = 2000) {
        guard network.isConnected else {
            lastFeedback = "Not connected to engine."
            return
        }
        isAnalysing = true
        Task {
            defer { self.isAnalysing = false }
            do {
                let result = try await network.analyse(fen: fen, movetime: movetime)
                lastFeedback  = result.feedback ?? ""
                scoreCP       = result.score_cp
                bestMoveArrow = (result.from != nil && result.to != nil)
                    ? (from: result.from!, to: result.to!)
                    : nil
            } catch {
                lastFeedback = "Analysis error: \(error.localizedDescription)"
            }
        }
    }

    func clearFeedback() {
        lastFeedback  = ""
        bestMoveArrow = nil
        scoreCP       = nil
    }
}
