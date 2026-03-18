// AppStore.swift
// Dacelo
//
// Root coordinator. Owns and wires all child stores and services.
// Injected into the view hierarchy as an @EnvironmentObject from DaceloApp.
//
// Ownership graph:
//   AppStore
//     ├── AppSettings       — persisted user preferences (@AppStorage)
//     ├── EngineConnectionState — WebSocket connection status (@Published, MainActor)
//     ├── EngineService     — WebSocket client (Swift actor)
//     ├── GameStore         — live chess game state (ChessStore wrapper, MainActor)
//     └── AnalysisStore     — move analysis, critiques, LLM contexts (MainActor)
//
// Key flows:
//   connectToServer()     → EngineService.connect() + queryEngines() → AppSettings.availableEngines
//   enterReviewMode()     → sets gameMode = .analysisOnly, fires fillMissingNarratives()
//   newGame()             → resets GameStore + AnalysisStore, re-attaches observation

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
    }

    // MARK: - Connection

    func connectToServer() {
        Task {
            await engine.configure(host: settings.serverHost, port: settings.serverPort)
            await engine.connect()
            // Immediately ask the server what engines it has registered.
            // This populates the live pickers in SettingsView so the user
            // never has to type engine names manually.
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

    /// Query the server for its registered engine list and store in AppSettings.
    /// Called automatically on connect; can also be triggered manually from Settings.
    func refreshAvailableEngines() async {
        let names = await engine.queryEngines()
        settings.availableEngines = names

        // If the user's saved engine names are no longer valid (e.g. they moved
        // to a different server), fall back to the first available engine so
        // nothing silently breaks.
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

    /// Enter analysis mode WITHOUT clearing move history.
    /// Called from the toolbar toggle so the current game's critiques are
    /// preserved and the user can browse them immediately.
    func enterAnalysisMode() {
        gameStore.gameMode = .analysisOnly
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
        analysis.fillMissingNarratives()
    }

    /// Switch to analysis mode and fill any LLM narratives that didn't
    /// generate during play (e.g. LLM was offline).
    func enterReviewMode() {
        gameStore.gameMode = .analysisOnly
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
        analysis.fillMissingNarratives()
    }
    
    /// Return to humanVsEngine from analysis mode WITHOUT resetting the game.
    func exitAnalysisMode() {
        gameStore.gameMode = .humanVsEngine
        gameStore.clearPositionOverride()
        analysis.clearCritiqueSelection()
        // Re-observe so the engine robot (if any) resumes normally.
        // preserveHistory: true keeps all the critiques visible.
        analysis.observe(gameStore, settings: settings, preserveHistory: true)
    }
}
