// AnalysisService.swift
// Dacelo
//
// Manages position analysis and move critique tracking

import Foundation
import Combine
import Chess

@MainActor
final class AnalysisService: ObservableObject {

    // MARK: - Published State

    @Published var lastFeedback: String = ""
    @Published var bestMoveArrow: (from: String, to: String)? = nil
    @Published var isAnalysing: Bool = false
    @Published var scoreCP: Int? = nil
    @Published var currentCharacteristics: PositionCharacteristics? = nil

    @Published var moveCritiques: [MoveCritique] = []
    @Published var moveHistory: [String] = []

    // MARK: - Private State

    private let network: NetworkService
    private var lastEval: Int? = nil
    private var moveCount: Int = 0

    /// Serialises all engine calls. The server's UCI engine is single-threaded;
    /// concurrent requests from analyse() and recordMove() cause a deadlock.
    /// Every network call goes through this queue — one at a time.
    private var requestQueue: Task<Void, Never>? = nil

    // MARK: - Initialization

    init(network: NetworkService) {
        self.network = network
    }

    // MARK: - Public API

    /// Request position analysis. Cancels any pending analysis (not in-flight),
    /// then enqueues behind any currently executing request.
    func analyse(fen: String, movetime: Int = 2000) {
        guard network.isConnected else {
            lastFeedback = "Not connected to engine."
            return
        }

        enqueue {
            await self.runAnalyse(fen: fen, movetime: movetime)
        }
    }

    func recordMove(
        move: String,
        moveNotation: String,
        side: String,
        fen: String
    ) {
        moveCount += 1
        moveHistory.append(moveNotation)

        enqueue {
            await self.runRecordMove(
                move: move,
                moveNotation: moveNotation,
                side: side,
                fen: fen,
                moveNumber: self.moveCount
            )
        }
    }

    func clearHistory() {
        moveCritiques.removeAll()
        moveHistory.removeAll()
        lastEval = nil
        moveCount = 0
        clearFeedback()
    }

    func clearFeedback() {
        lastFeedback = ""
        bestMoveArrow = nil
        scoreCP = nil
        currentCharacteristics = nil
    }

    // MARK: - Queue

    /// Enqueues work so requests never overlap on the wire.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = requestQueue
        requestQueue = Task {
            // Wait for the previous task to finish first
            await previous?.value
            await work()
        }
    }

    // MARK: - Private implementations

    private func runAnalyse(fen: String, movetime: Int) async {
        isAnalysing = true
        defer { isAnalysing = false }
        do {
            let result = try await network.analyse(fen: fen, movetime: movetime)
            lastFeedback = result.feedback ?? ""
            scoreCP = result.score_cp
            currentCharacteristics = result.characteristics
            if let from = result.from, let to = result.to, !from.isEmpty, !to.isEmpty {
                bestMoveArrow = (from: from, to: to)
            } else {
                bestMoveArrow = nil
            }
        } catch {
            lastFeedback = "Analysis error: \(error.localizedDescription)"
            bestMoveArrow = nil
        }
    }

    private func runRecordMove(
        move: String,
        moveNotation: String,
        side: String,
        fen: String,
        moveNumber: Int
    ) async {
        do {
            let result = try await network.analyse(fen: fen, movetime: 2000)

            let classification = classifyMove(
                prevScore: lastEval,
                currScore: result.score_cp,
                alternatives: result.alternatives
            )

            let alternatives = (result.alternatives ?? []).map { alt in
                AlternativeMove(
                    rank: alt.rank,
                    move: alt.move ?? "",
                    scoreCP: alt.score_cp,
                    scoreMate: alt.score_mate
                )
            }

            let critique = MoveCritique(
                moveNumber: moveNumber,
                side: side,
                move: move,
                moveNotation: moveNotation,
                scoreBefore: lastEval,
                scoreAfter: result.score_cp,
                classification: classification.quality,
                comment: classification.comment,
                alternatives: alternatives,
                characteristics: result.characteristics
            )

            moveCritiques.append(critique)
            lastEval = result.score_cp

            // Also update the live panel with the latest eval
            scoreCP = result.score_cp
            lastFeedback = result.feedback ?? ""

        } catch {
            print("[AnalysisService] Failed to record move: \(error)")
        }
    }

    // MARK: - Classification

    private func classifyMove(
        prevScore: Int?,
        currScore: Int?,
        alternatives: [AlternativeMoveResponse]?
    ) -> (quality: MoveQuality, comment: String) {

        guard let prev = prevScore, let curr = currScore else {
            return (.unknown, "")
        }

        if let alts = alternatives, let best = alts.first, let bestScore = best.score_cp {
            let cpLoss = abs(curr - bestScore)
            if cpLoss <= 10 {
                return (.excellent, "Best move!")
            } else if cpLoss <= 20 {
                return (.good, "Good move.")
            } else if cpLoss <= 50 {
                return (.inaccuracy, String(format: "Lost %.2f pawns. Better: %@",
                                            Double(cpLoss) / 100.0, best.move ?? ""))
            } else if cpLoss <= 100 {
                return (.mistake, String(format: "Lost %.2f pawns! Better: %@",
                                         Double(cpLoss) / 100.0, best.move ?? ""))
            } else {
                return (.blunder, String(format: "Lost %.2f pawns!! Better: %@",
                                         Double(cpLoss) / 100.0, best.move ?? ""))
            }
        }

        let change = curr - prev
        if abs(change) < 20 {
            return (.good, "Maintains the position.")
        } else if change < -50 {
            return (.mistake, "Worsened the position.")
        } else {
            return (.unknown, "")
        }
    }
}
