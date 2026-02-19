// AppStore.swift
// Dacelo

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
    @Published var moveTimeMs: Int = 3000

    @AppStorage("serverHost") var serverHost: String = "your-pc-hostname"
    @AppStorage("serverPort") var serverPort: Int = 8765

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

        let (white, black) = makePlayers(for: gameMode)
        let store = ChessStore(game: Chess.Game(white, against: black))

        chessStore = store
        analysis.clearHistory()
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

    private func makePlayers(for mode: GameMode) -> (Chess.Player, Chess.Player) {
        switch mode {
        case .humanVsEngine:
            let bot = Lc0Robot(
                side: .black,
                serverHost: serverHost,
                serverPort: serverPort,
                moveTimeMs: moveTimeMs
            )
            return (Chess.HumanPlayer(side: .white), bot)

        case .engineVsHuman:
            let bot = Lc0Robot(
                side: .white,
                serverHost: serverHost,
                serverPort: serverPort,
                moveTimeMs: moveTimeMs
            )
            return (bot, Chess.HumanPlayer(side: .black))

        case .humanVsHuman, .analysisOnly:
            return (
                Chess.HumanPlayer(side: .white),
                Chess.HumanPlayer(side: .black)
            )
        }
    }

    private func setupMoveObserver() {
        cancellables.removeAll()

        chessStore.$game
            .removeDuplicates { $0.board.FEN == $1.board.FEN }
            .dropFirst()
            .sink { [weak self] game in
                guard let self else { return }
                let fen = game.board.FEN
                let fenParts = fen.split(separator: " ").map(String.init)

                // The FEN's active color is who moves NEXT — so the mover is the opposite
                let activeColor = fenParts.count > 1 ? fenParts[1] : "w"
                let sideJustMoved = activeColor == "w" ? "black" : "white"

                // Derive move number from FEN fullmove clock (field 6, 1-indexed)
                let fullMove = Int(fenParts.count > 5 ? fenParts[5] : "1") ?? 1
                let moveLabel: String
                if sideJustMoved == "white" {
                    moveLabel = "\(fullMove)."
                } else {
                    moveLabel = "\(max(1, fullMove - 1))..."
                }

                self.analysis.recordMove(
                    move: moveLabel,
                    moveNotation: moveLabel,
                    side: sideJustMoved,
                    fen: fen
                )
            }
            .store(in: &cancellables)
    }
}
