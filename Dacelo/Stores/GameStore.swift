// GameStore.swift
// Dacelo
//
// Owns the Chess game state and player configuration.
// Knows nothing about analysis — AnalysisStore observes
// this store's published game independently.

import Chess
import SwiftUI
import Combine

// MARK: - Game Mode

enum GameMode: String, CaseIterable, Identifiable {
    case humanVsEngine = "You vs Leela"
    case engineVsHuman = "Leela vs You"
    case humanVsHuman  = "Two Players"
    case analysisOnly  = "Analysis Mode"
    var id: String { rawValue }
}

// MARK: - GameStore

@MainActor
final class GameStore: ObservableObject {

    @Published var chessStore: ChessStore
    @Published var gameMode: GameMode = .humanVsEngine

    private let engine: EngineService
    private let settings: AppSettings

    init(engine: EngineService, settings: AppSettings) {
        self.engine   = engine
        self.settings = settings

        // Start with a placeholder — newGame() replaces it immediately
        chessStore = ChessStore(game: Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        ))

        newGame(mode: .humanVsEngine)
    }

    // MARK: - Public API

    func newGame(mode: GameMode? = nil) {
        if let mode { gameMode = mode }
        let (white, black) = makePlayers(for: gameMode)
        chessStore = ChessStore(game: Chess.Game(white, against: black))

        Task { await engine.newGame() }
    }

    // MARK: - Private

    private func makePlayers(for mode: GameMode) -> (Chess.Player, Chess.Player) {
        switch mode {
        case .humanVsEngine:
            return (
                Chess.HumanPlayer(side: .white),
                Lc0Robot(side: .black, engine: engine, moveTimeMs: settings.moveTimeMs)
            )
        case .engineVsHuman:
            return (
                Lc0Robot(side: .white, engine: engine, moveTimeMs: settings.moveTimeMs),
                Chess.HumanPlayer(side: .black)
            )
        case .humanVsHuman, .analysisOnly:
            return (
                Chess.HumanPlayer(side: .white),
                Chess.HumanPlayer(side: .black)
            )
        }
    }
}
