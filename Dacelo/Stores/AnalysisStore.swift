// AnalysisStore.swift
// Dacelo
//
// Observes GameStore for position changes, calls EngineService
// for analysis, and maintains the full move critique history.
//
// Key fix over the old AnalysisService:
//   - scoreBefore comes from the analysis of the PREVIOUS position
//     (stored as prevEval after each move), not a stale lastEval field.
//   - classifyMove uses side-normalised scores so cp loss is always
//     "how much worse did this make MY position" regardless of colour.

import Foundation
import Combine
import Chess

@MainActor
final class AnalysisStore: ObservableObject {

    // MARK: - Published State

    @Published var moveCritiques: [MoveCritique] = []
    @Published var lastFeedback: String          = ""
    @Published var bestMoveArrow: (from: String, to: String)? = nil
    @Published var isAnalysing: Bool             = false
    @Published var scoreCP: Int?                 = nil
    @Published var currentCharacteristics: PositionCharacteristics? = nil

    // MARK: - Private

    private let engine: EngineService
    private var cancellables: Set<AnyCancellable> = []

    /// The normalised (white-positive) eval of the most recently
    /// analysed position. Used as scoreBefore for the next move.
    private var prevEval: Int? = nil
    private var moveCount: Int = 0

    /// Serial task queue — one engine call at a time.
    private var tail: Task<Void, Never>?

    // MARK: - Init

    init(engine: EngineService) {
        self.engine = engine
    }

    // MARK: - Public API

    /// Attach to a GameStore. Call this whenever a new game starts.
    func observe(_ gameStore: GameStore) {
        cancellables.removeAll()
        clearHistory()

        gameStore.$chessStore
            .flatMap { $0.$game }
            .removeDuplicates { $0.board.FEN == $1.board.FEN }
            .dropFirst()
            .sink { [weak self] game in
                self?.handlePositionChange(game)
            }
            .store(in: &cancellables)
    }

    func clearHistory() {
        moveCritiques.removeAll()
        prevEval  = nil
        moveCount = 0
        clearLivePanel()
    }

    func clearLivePanel() {
        lastFeedback          = ""
        bestMoveArrow         = nil
        scoreCP               = nil
        currentCharacteristics = nil
    }

    // MARK: - Position change handler

    private func handlePositionChange(_ game: Chess.Game) {
        let fen      = game.board.FEN
        let fenParts = fen.split(separator: " ").map(String.init)

        // Active colour is who moves NEXT → mover is the opposite
        let activeColor   = fenParts.count > 1 ? fenParts[1] : "w"
        let sideJustMoved = activeColor == "w" ? "black" : "white"

        // Full-move number from FEN field 6
        let fullMove  = Int(fenParts.count > 5 ? fenParts[5] : "1") ?? 1
        let moveLabel = sideJustMoved == "white"
            ? "\(fullMove)."
            : "\(max(1, fullMove - 1))..."

        moveCount += 1
        let capturedMoveCount = moveCount
        let capturedPrevEval  = prevEval   // snapshot before the enqueue

        enqueue {
            await self.runMoveAnalysis(
                fen:       fen,
                side:      sideJustMoved,
                notation:  moveLabel,
                moveNumber: capturedMoveCount,
                prevEval:  capturedPrevEval
            )
        }
    }

    // MARK: - Analysis

    private func runMoveAnalysis(
        fen: String,
        side: String,
        notation: String,
        moveNumber: Int,
        prevEval: Int?
    ) async {
        isAnalysing = true
        defer { isAnalysing = false }

        do {
            let result = try await engine.analyse(fen: fen, movetime: 2000)

            // Normalise score to white-positive
            let fenParts     = fen.split(separator: " ").map(String.init)
            let activeColor  = fenParts.count > 1 ? fenParts[1] : "w"
            let normScore    = normalise(cp: result.score_cp, activeColor: activeColor)

            // Classify using correctly-normalised scores
            let classification = classifyMove(
                prevEval:    prevEval,
                currEval:    normScore,
                side:        side,
                alternatives: result.alternatives,
                activeColor: activeColor
            )

            let alternatives = (result.alternatives ?? []).map {
                AlternativeMove(
                    rank:      $0.rank,
                    move:      $0.move ?? "",
                    scoreCP:   normalise(cp: $0.score_cp, activeColor: activeColor),
                    scoreMate: $0.score_mate
                )
            }

            let critique = MoveCritique(
                moveNumber:     moveNumber,
                side:           side,
                move:           notation,
                moveNotation:   notation,
                scoreBefore:    prevEval,
                scoreAfter:     normScore,
                classification: classification.quality,
                comment:        classification.comment,
                alternatives:   alternatives,
                characteristics: result.characteristics
            )

            moveCritiques.append(critique)

            // Update live panel
            self.prevEval             = normScore
            self.scoreCP              = normScore
            self.lastFeedback         = result.feedback ?? ""
            self.currentCharacteristics = result.characteristics

            if let from = result.from, let to = result.to, !from.isEmpty, !to.isEmpty {
                bestMoveArrow = (from: from, to: to)
            } else {
                bestMoveArrow = nil
            }

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

    /// lc0 reports score from side-to-move perspective (positive = mover is better).
    /// We normalise to white-positive so all stored evals are comparable.
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

        guard let prev = prevEval, let curr = currEval else {
            return (.unknown, "")
        }

        // cp loss from the moving side's perspective:
        // white wants score to go up; black wants it to go down.
        // A positive cpLoss means the position got worse for the mover.
        let cpLoss = side == "white" ? (prev - curr) : (curr - prev)

        // Use best alternative as the anchor for what was achievable
        let bestMove: String
        if let alts = alternatives,
           let best = alts.first(where: { $0.score_cp != nil }) {
            bestMove = best.move ?? ""
        } else {
            bestMove = ""
        }

        let lostPawns = Double(max(0, cpLoss)) / 100.0
        let betterStr = bestMove.isEmpty ? "" : " Better: \(bestMove)"

        switch cpLoss {
        case ..<10:
            return (.excellent,  "Best move!")
        case ..<25:
            return (.good,       "Good move.")
        case ..<50:
            return (.inaccuracy, String(format: "Inaccuracy — lost %.2f pawns.\(betterStr)", lostPawns))
        case ..<100:
            return (.mistake,    String(format: "Mistake — lost %.2f pawns!\(betterStr)", lostPawns))
        default:
            return (.blunder,    String(format: "Blunder — lost %.2f pawns!!\(betterStr)", lostPawns))
        }
    }
}
