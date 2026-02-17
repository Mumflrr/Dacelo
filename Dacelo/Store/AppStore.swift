// AppStore.swift
// LeelaChessApp

import Chess
import SwiftUI
import Combine

// MARK: - Game Mode

enum GameMode: String, CaseIterable, Identifiable {
    case humanVsEngine  = "You vs Leela"
    case engineVsHuman  = "Leela vs You"
    case humanVsHuman   = "Two Players"
    case analysisOnly   = "Analysis Mode"
    var id: String { rawValue }
}

// MARK: - AppStore

@MainActor
final class AppStore: ObservableObject {

    let network = NetworkService()
    @Published var analysis: AnalysisService
    @Published var chessStore: ChessStore
    @Published var gameMode: GameMode = .humanVsEngine
    @Published var moveTimeMs: Int    = 3000

    @AppStorage("serverHost") var serverHost: String = "your-pc-hostname"
    @AppStorage("serverPort") var serverPort: Int    = 8765

    private var cancellables: Set<AnyCancellable> = []

    init() {
        analysis = AnalysisService(network: network)

        let white = Chess.HumanPlayer(side: .white)
        let black = Chess.HumanPlayer(side: .black)
        chessStore = ChessStore(game: Chess.Game(white, against: black))

        network.serverHost = serverHost
        network.serverPort = serverPort

        newGame(mode: .humanVsEngine)
    }

    // MARK: - Public API

    func newGame(mode: GameMode? = nil) {
        if let mode { gameMode = mode }

        let (white, black, whiteBot, blackBot) = makePlayers(for: gameMode)
        let store = ChessStore(game: Chess.Game(white, against: black))

        // Wire the store reference into any Lc0Robot instances so they can
        // dispatch moves back via store.gameAction(.makeMove(move:))
        whiteBot?.store = store
        blackBot?.store = store

        // Give the network call enough time before the nil evalutate resign fires.
        // responseDelay pauses the robot before calling evalutate, buying us time.
        let delaySeconds = Double(moveTimeMs) / 1000.0 + 1.0
        whiteBot?.responseDelay = delaySeconds
        blackBot?.responseDelay = delaySeconds

        chessStore = store
        analysis.clearFeedback()
        setupMoveObserver()
    }

    func connectToServer() {
        network.serverHost = serverHost
        network.serverPort = serverPort
        network.connect()
    }

    func disconnectFromServer() {
        network.disconnect()
    }

    // MARK: - Private

    // Returns players plus optional Lc0Robot refs for post-init wiring.
    private func makePlayers(for mode: GameMode)
        -> (Chess.Player, Chess.Player, Lc0Robot?, Lc0Robot?) {

        switch mode {
        case .humanVsEngine:
            let bot = Lc0Robot(side: .black, network: network, moveTimeMs: moveTimeMs)
            return (Chess.HumanPlayer(side: .white), bot, nil, bot)

        case .engineVsHuman:
            let bot = Lc0Robot(side: .white, network: network, moveTimeMs: moveTimeMs)
            return (bot, Chess.HumanPlayer(side: .black), bot, nil)

        case .humanVsHuman, .analysisOnly:
            return (
                Chess.HumanPlayer(side: .white),
                Chess.HumanPlayer(side: .black),
                nil, nil
            )
        }
    }

    private func setupMoveObserver() {
        cancellables.removeAll()

        // board.FEN is a computed String (uppercase) from Board+FEN.swift
        chessStore.$game
            .map { $0.board.FEN }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] fen in
                guard let self else { return }
                switch self.gameMode {
                case .humanVsEngine, .humanVsHuman, .analysisOnly:
                    self.analysis.analyse(fen: fen, movetime: 2000)
                case .engineVsHuman:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
