// AnalysisStore.swift
// Dacelo

import Foundation
import Combine
import Chess

@MainActor
final class AnalysisStore: ObservableObject {

    // MARK: - Published State

    @Published var moveCritiques: [MoveCritique] = []
    @Published var lastFeedback: String          = ""
    @Published var bestMoveArrow: (from: String, to: String)? = nil
    @Published var isRequestingHint: Bool        = false
    @Published var isAnalysing: Bool             = false
    @Published var scoreCP: Int?                 = nil
    @Published var currentCharacteristics: PositionCharacteristics? = nil
    @Published var currentPV: [String]           = []
    /// Index into moveCritiques for the currently-highlighted move card. nil = latest.
    @Published var selectedCritiqueIndex: Int?   = nil

    var canGoBack: Bool    { !moveCritiques.isEmpty && (selectedCritiqueIndex ?? moveCritiques.count - 1) > 0 }
    var canGoForward: Bool { selectedCritiqueIndex != nil && selectedCritiqueIndex! < moveCritiques.count - 1 }

    func goBack() {
        guard !moveCritiques.isEmpty else { return }
        let current = selectedCritiqueIndex ?? (moveCritiques.count - 1)
        selectedCritiqueIndex = max(0, current - 1)
    }
    func goForward() {
        guard let idx = selectedCritiqueIndex else { return }
        let next = idx + 1
        selectedCritiqueIndex = next >= moveCritiques.count ? nil : next
    }

    // MARK: - Private

    private let engine: EngineService
    private weak var gameStore:   GameStore?
    private weak var appSettings: AppSettings?
    private var cancellables: Set<AnyCancellable> = []

    private var prevEval: Int? = nil
    private var moveCount: Int = 0
    private var tail: Task<Void, Never>?

    // MARK: - Init

    init(engine: EngineService) {
        self.engine = engine
    }

    // MARK: - Public API

    func observe(_ gameStore: GameStore, settings: AppSettings? = nil) {
        self.gameStore   = gameStore
        self.appSettings = settings
        cancellables.removeAll()
        clearHistory()

        gameStore.$chessStore
            .flatMap { $0.$game }
            .removeDuplicates { $0.board.FEN == $1.board.FEN }
            .dropFirst()
            .sink { [weak self] game in
                // Dispatch to avoid publishing changes during view updates
                DispatchQueue.main.async {
                    self?.handlePositionChange(game)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Hint
    /// Requests the best move arrow. Loading indicator stays on until the arrow
    /// is visible. Arrow persists until the next move is made.
    func requestHint(count: Int = 1) {
        guard let fen = gameStore?.currentFEN, !fen.isEmpty else { return }
        guard !isRequestingHint else { return }
        isRequestingHint = true
        Task {
            do {
                let result = try await engine.analyse(fen: fen, movetime: 1500)
                if let from = result.from, let to = result.to,
                   !from.isEmpty, !to.isEmpty {
                    bestMoveArrow = (from: from, to: to)
                }
            } catch {
                print("[AnalysisStore] Hint failed: \(error.localizedDescription)")
            }
            // Stop loading only after the arrow has been set (or failed)
            isRequestingHint = false
        }
    }

    func clearHistory() {
        moveCritiques.removeAll()
        selectedCritiqueIndex = nil
        prevEval  = nil
        moveCount = 0
        clearLivePanel()
    }

    func clearLivePanel() {
        lastFeedback           = ""
        bestMoveArrow          = nil
        scoreCP                = nil
        currentCharacteristics = nil
        currentPV              = []
    }

    // MARK: - Position change handler

    private func handlePositionChange(_ game: Chess.Game) {
        let fen      = game.board.FEN
        // Starting position — don't analyse, happens after newGame() resets the board.
        guard !fen.hasPrefix("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR") else { return }

        // A move was made — clear any displayed hint arrow
        bestMoveArrow = nil

        let fenParts = fen.split(separator: " ").map(String.init)

        let activeColor   = fenParts.count > 1 ? fenParts[1] : "w"
        let sideJustMoved = activeColor == "w" ? "black" : "white"

        let fullMove   = Int(fenParts.count > 5 ? fenParts[5] : "1") ?? 1
        // FEN fullmove increments AFTER black's move (active becomes "w").
        // • white just moved → active = "b", fullMove = N  → display N
        // • black just moved → active = "w", fullMove = N+1 → display N = fullMove - 1
        let displayNum = sideJustMoved == "white" ? fullMove : max(1, fullMove - 1)
        let movePrefix = sideJustMoved == "white" ? "\(displayNum)." : "\(displayNum)..."

        // Extract the last UCI move from game.board.turns.
        // Each Chess.Turn has a .white and optional .black Chess.Move.
        // The last played move is black's move in the last turn if it exists,
        // otherwise white's move in the last turn.
        let lastUCI: String
        let lastMove: Chess.Move? = {
            guard let lastTurn = game.board.turns.last else { return nil }
            return lastTurn.black ?? lastTurn.white
        }()
        if let move = lastMove,
           move.start.isBoardPosition,
           move.end.isBoardPosition {
            let from = move.start.FEN
            let to   = move.end.FEN
            var uci  = from + to
            if case .promotion(let piece) = move.sideEffect {
                switch piece {
                case .queen:  uci += "q"
                case .rook:   uci += "r"
                case .bishop: uci += "b"
                case .knight: uci += "n"
                default:      break
                }
            }
            lastUCI = uci
        } else {
            lastUCI = ""
        }

        // Extract piece type from the destination square after the move.
        // Since Position is just Int, move.end is the board index directly.
        let pieceType: String = {
            guard let move = lastMove, move.end.isBoardPosition else { return "p" }
            let destPiece = game.board.squares[move.end].piece
            switch destPiece?.pieceType {
            case .knight: return "n"
            case .bishop: return "b"
            case .rook:   return "r"
            case .queen:  return "q"
            case .king:   return "k"
            default:      return "p"
            }
        }()

        moveCount += 1
        let capturedMoveCount = moveCount
        let capturedPrevEval  = prevEval
        let capturedPieceType = pieceType

        enqueue {
            await self.runMoveAnalysis(
                fen:        fen,
                side:       sideJustMoved,
                movePrefix: movePrefix,
                lastUCI:    lastUCI,
                pieceType:  capturedPieceType,
                moveNumber: capturedMoveCount,
                prevEval:   capturedPrevEval
            )
        }
    }

    // MARK: - Analysis

    private func runMoveAnalysis(
        fen: String,
        side: String,
        movePrefix: String,   // e.g. "1." or "3..."
        lastUCI: String,      // e.g. "e2e4" — the actual move just played
        pieceType: String,    // "p","n","b","r","q","k"
        moveNumber: Int,
        prevEval: Int?
    ) async {
        isAnalysing = true
        defer { isAnalysing = false }

        do {
            let result = try await engine.analyse(fen: fen, movetime: 2000)

            let fenParts    = fen.split(separator: " ").map(String.init)
            let activeColor = fenParts.count > 1 ? fenParts[1] : "w"
            let normScore   = normalise(cp: result.score_cp, activeColor: activeColor)

            let classification = classifyMove(
                prevEval:     prevEval,
                currEval:     normScore,
                side:         side,
                alternatives: result.alternatives,
                activeColor:  activeColor
            )

            let alternatives = (result.alternatives ?? []).map {
                AlternativeMove(
                    rank:      $0.rank,
                    move:      $0.move ?? "",
                    scoreCP:   normalise(cp: $0.score_cp, activeColor: activeColor),
                    scoreMate: $0.score_mate,
                    pv:        $0.pv ?? []
                )
            }

            let critique = MoveCritique(
                moveNumber:      moveNumber,
                side:            side,
                move:            lastUCI,
                moveNotation:    movePrefix,
                pieceType:       pieceType,
                scoreBefore:     prevEval,
                scoreAfter:      normScore,
                classification:  classification.quality,
                comment:         classification.comment,
                alternatives:    alternatives,
                characteristics: result.characteristics,
                suggestedLine:   result.pv ?? [],
            )

            moveCritiques.append(critique)

            self.prevEval               = normScore
            self.scoreCP                = normScore
            self.lastFeedback           = result.feedback ?? ""
            self.currentCharacteristics = result.characteristics
            self.currentPV              = result.pv ?? []
            // Best-move arrow is shown only via hint — analysis never sets it

        } catch {
            print("[AnalysisStore] Analysis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Serial queue

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    // MARK: - Score normalisation

    private func normalise(cp: Int?, activeColor: String) -> Int? {
        guard let cp else { return nil }
        return activeColor == "w" ? cp : -cp
    }

    // MARK: - Move classification

    private func classifyMove(
        prevEval: Int?,
        currEval: Int?,
        side: String,
        alternatives: [AlternativeMoveResponse]?,
        activeColor: String
    ) -> (quality: MoveQuality, comment: String) {

        let prev = prevEval ?? 0
        guard let curr = currEval else { return (.unknown, "") }

        // Positive cpLoss = position got worse for the mover
        let cpLoss = side == "white" ? (prev - curr) : (curr - prev)

        // Best alternative move string for suggestions
        let bestAlt: AlternativeMoveResponse? = alternatives?.first(where: { $0.score_cp != nil })
        let bestMove = bestAlt?.move ?? ""
        let betterStr = bestMove.isEmpty ? "" : " Engine prefers \(formatUCI(bestMove))."

        let lostPawns = Double(max(0, cpLoss)) / 100.0

        switch cpLoss {
        case ..<10:
            return (.excellent,
                    "Best move! The engine agrees this is the top choice.")
        case ..<25:
            let cp = cpLoss
            return (.good,
                    "Good move — only \(cp)cp from optimal.\(betterStr)")
        case ..<50:
            return (.inaccuracy,
                    String(format: "Inaccuracy — %.2f pawns from optimal.\(betterStr) "
                           + "A better continuation was available.", lostPawns))
        case ..<100:
            return (.mistake,
                    String(format: "Mistake — %.2f pawns lost.\(betterStr) "
                           + "This significantly weakens your position.", lostPawns))
        default:
            return (.blunder,
                    String(format: "Blunder — %.2f pawns lost!\(betterStr) "
                           + "This fundamentally changes the game's outcome.", lostPawns))
        }
    }

    /// Format a UCI move (e.g. "e2e4") as a readable "e2→e4" string.
    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from = String(uci.prefix(2))
        let to   = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}
