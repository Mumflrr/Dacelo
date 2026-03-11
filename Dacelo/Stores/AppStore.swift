// AppStore.swift
// Dacelo
// Stores/

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
    // Order matters:
    //   1. AppSettings and EngineConnectionState are @MainActor — create first
    //   2. EngineService (actor) receives state as a parameter — no MainActor init call inside actor
    //   3. GameStore and AnalysisStore depend on engine

    init() {
        let s     = AppSettings()
        let eState = EngineConnectionState()   // created here on MainActor ✓
        let eng   = EngineService(host: s.serverHost, port: s.serverPort, state: eState)
        let game  = GameStore(engine: eng, settings: s)
        let ana   = AnalysisStore(engine: eng)

        self.settings    = s
        self.engineState = eState
        self.engine      = eng
        self.gameStore   = game
        self.analysis    = ana

        ana.observe(game)
    }

    // MARK: - Connection

    func connectToServer() {
        Task {
            await engine.configure(host: settings.serverHost, port: settings.serverPort)
            await engine.connect()
        }
    }

    func disconnectFromServer() {
        Task { await engine.disconnect() }
    }

    // MARK: - New Game

    func newGame(mode: GameMode? = nil) {
        gameStore.newGame(mode: mode)
        analysis.clearHistory()
        analysis.observe(gameStore)
    }
}
