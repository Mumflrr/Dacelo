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

    func newGame(mode: GameMode? = nil, playerColor: PlayerColor? = nil) {
        if let mode        { gameStore.gameMode    = mode }
        if let playerColor { gameStore.playerColor = playerColor }
        gameStore.newGame()
        analysis.clearHistory()
        analysis.observe(gameStore)
    }
}
