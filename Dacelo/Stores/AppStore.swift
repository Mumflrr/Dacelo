// AppStore.swift
// Dacelo

import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {

    // MARK: - Child stores
    let settings:    AppSettings
    let engineState: EngineConnectionState
    let engine:      EngineService
    let gameStore:   GameStore
    let analysis:    AnalysisStore

    // MARK: - Init

    init() {
        let s      = AppSettings()
        let eState = EngineConnectionState()
        let eng    = EngineService(host: s.serverHost, port: s.serverPort, state: eState)
        let game   = GameStore(engine: eng, settings: s)
        let ana    = AnalysisStore(engine: eng)

        self.settings    = s
        self.engineState = eState
        self.engine      = eng
        self.gameStore   = game
        self.analysis    = ana

        ana.observe(game, settings: s)
        ana.observeScratch(game)

        // Auto-connect on launch.
        Task { await eng.connect() }
    }

    // MARK: - Connection

    func connectToServer() {
        Task {
            await engine.configure(host: settings.serverHost, port: settings.serverPort)
            await engine.connect()
            await refreshAvailableEngines()
        }
    }

    func disconnectFromServer() {
        Task {
            await engine.disconnect()
            settings.availableEngines = []
        }
    }

    // MARK: - Engine discovery

    func refreshAvailableEngines() async {
        let names = await engine.queryEngines()
        settings.availableEngines = names
        if !names.isEmpty {
            if !names.contains(settings.evalEngine)     { settings.evalEngine     = names.first! }
            if !names.contains(settings.bestMoveEngine) { settings.bestMoveEngine = names.first! }
            if !names.contains(settings.nnueEngine)     { settings.nnueEngine     = names.first! }
        }
    }

    // MARK: - New Game

    func newGame(mode: GameMode? = nil, playerColor: PlayerColor? = nil) {
        if let mode        { gameStore.gameMode    = mode }
        if let playerColor { gameStore.playerColor = playerColor }
        gameStore.newGame()
        analysis.clearHistory()
        analysis.observe(gameStore, settings: settings)
    }

    // MARK: - Analysis / Review Mode

    func enterAnalysisMode() {
        gameStore.gameMode = .analysisOnly
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
        analysis.fillMissingNarratives()
    }

    func enterReviewMode() {
        gameStore.gameMode = .analysisOnly
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
        analysis.fillMissingNarratives()
    }

    func exitAnalysisMode() {
        gameStore.gameMode = .humanVsEngine
        gameStore.clearHistoryReview()
        analysis.clearCritiqueSelection()
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
    }
}
