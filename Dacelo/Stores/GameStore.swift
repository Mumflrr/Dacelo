// GameStore.swift
// Dacelo
//
// Manages the live chess game. Wraps the swift-chess ChessStore and
// bridges it to the app's engine and settings.
//
// Game modes:
//   humanVsEngine  — player vs UCI engine (UCIRobot on engine's side)
//   humanVsHuman   — two human players, engine analyses only
//   analysisOnly   — two human players + full deep analysis + LLM commentary.
//                    Board accepts free moves from both sides. The move history
//                    drawer is the primary review navigator: selecting a critique
//                    shows that position; deselecting returns to the live position.
//
// Robot pause flow (humanVsEngine):
//   togglePause() sets robotController.isPaused.
//   UCIRobot.evaluate() polls this and blocks in waitForManualMoveOrResume().
//   User can drag/tap squares on the engine's behalf while paused.

import Chess
import SwiftUI
import Combine

// MARK: - Player Color

enum PlayerColor: String, CaseIterable, Identifiable {
    case white = "White"
    case black = "Black"
    var id: String { rawValue }
    var opposite: PlayerColor { self == .white ? .black : .white }
    var chessSide: Chess.Side { self == .white ? .white : .black }
}

// MARK: - Game Mode

enum GameMode: String, CaseIterable, Identifiable {
    case humanVsEngine = "vs Engine"
    case humanVsHuman  = "Two Players"
    case analysisOnly  = "Analysis"

    var id: String { rawValue }

    /// True when deep analytics, NNUE breakdown, and LLM commentary are active.
    /// In analysis mode the board accepts free moves from both sides and the
    /// move history drawer doubles as a review navigator.
    var isAnalysis: Bool { self == .analysisOnly }
}

// MARK: - Board Theme

enum BoardTheme: String, CaseIterable, Identifiable {
    case brown    = "Brown"
    case blue     = "Blue"
    case green    = "Green"
    case purple   = "Purple"
    case mono     = "Mono"
    case slate    = "Slate"
    case coral    = "Coral"
    case midnight = "Midnight"

    var id: String { rawValue }

    var libraryColor: Chess.UI.BoardColor? {
        switch self {
        case .brown:  return .brown
        case .blue:   return .blue
        case .green:  return .green
        case .purple: return .purple
        default:      return nil
        }
    }

    var dark: Color {
        switch self {
        case .brown:    return Color(red: 0xae/255, green: 0x8a/255, blue: 0x68/255)
        case .blue:     return Color(red: 0x90/255, green: 0xa1/255, blue: 0xac/255)
        case .green:    return Color(red: 0x8c/255, green: 0xa5/255, blue: 0x6d/255)
        case .purple:   return Color(red: 0x76/255, green: 0x4c/255, blue: 0x89/255)
        case .mono:     return Color(white: 0.25)
        case .slate:    return Color(red: 0x44/255, green: 0x55/255, blue: 0x66/255)
        case .coral:    return Color(red: 0xc0/255, green: 0x60/255, blue: 0x5a/255)
        case .midnight: return Color(red: 0x1a/255, green: 0x2a/255, blue: 0x4a/255)
        }
    }

    var light: Color {
        switch self {
        case .brown:    return Color(red: 0xec/255, green: 0xda/255, blue: 0xb9/255)
        case .blue:     return Color(red: 0xdf/255, green: 0xe3/255, blue: 0xe6/255)
        case .green:    return Color(red: 0xff/255, green: 0xff/255, blue: 0xe0/255)
        case .purple:   return Color(red: 0x9c/255, green: 0x91/255, blue: 0xae/255)
        case .mono:     return Color(white: 0.88)
        case .slate:    return Color(red: 0xb0/255, green: 0xbc/255, blue: 0xcc/255)
        case .coral:    return Color(red: 0xf5/255, green: 0xd5/255, blue: 0xc8/255)
        case .midnight: return Color(red: 0x8a/255, green: 0xa8/255, blue: 0xd8/255)
        }
    }
}

// MARK: - GameStore

@MainActor
final class GameStore: ObservableObject {

    @Published var chessStore:  ChessStore
    @Published var gameMode:    GameMode    = .humanVsEngine
    @Published var playerColor: PlayerColor = .white
    @Published var boardTheme:  BoardTheme  = .brown
    @Published var isPaused:    Bool        = false
    @Published var currentFEN:  String      = ""
    /// When non-nil the board shows this FEN instead of the live game position.
    /// Set by selectCritique() in AnalysisStore; cleared by clearPositionOverride().
    @Published var positionOverrideFEN: String? = nil
    /// A temporary, standalone game used for exploring alternate lines from a
    /// historical position. Moves made here never enter moveCritiques.
    /// Nil when not in scratch exploration mode.
    @Published var scratchChessStore: ChessStore? = nil
    /// True while the user is in the middle of a two-tap manual move for Leela.
    /// Exposed so DaceloboardView can show a selection highlight on the first tap.
    @Published var manualSelectIdx: Int? = nil

    /// The FEN the board should display: override when reviewing history, live otherwise.
    var displayFEN: String { positionOverrideFEN ?? currentFEN }
    /// True when the user is making moves in a historical scratch position.
    var isExploringScratch: Bool { scratchChessStore != nil }
    /// The ChessStore the board renders. Updated by showPosition(), clearPositionOverride(),
    /// beginScratchExploration(), and endScratchExploration(). Always a stable reference
    /// so SwiftUI's @EnvironmentObject injection stays consistent.
    @Published var displayChessStore: ChessStore = ChessStore(game: Chess.Game(
        Chess.HumanPlayer(side: .white),
        against: Chess.HumanPlayer(side: .black)
    ))


    // MARK: - Robot controller
    //
    // One controller per game. Replaced on every newGame() so the old robot's
    // thread sees isCancelled and exits cleanly.

    private(set) var robotController = RobotController()

    private let engine:   EngineService
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    init(engine: EngineService, settings: AppSettings) {
        self.engine   = engine
        self.settings = settings
        chessStore = ChessStore(game: Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        ))
        newGame()
    }

    // MARK: - New Game

    func newGame() {
        if let robot = chessStore.game.black as? UCIRobot { robot.robotController?.isCancelled = true }
        if let robot = chessStore.game.white as? UCIRobot { robot.robotController?.isCancelled = true }
        robotController = RobotController()

        isPaused       = false
        manualSelectIdx = nil

        let (white, black) = makePlayers()
        let store = ChessStore(game: Chess.Game(white, against: black))
        applyTheme(to: store)
        chessStore = store
        displayChessStore = store
        currentFEN = store.game.board.FEN

        cancellables.removeAll()
        chessStore.$game
            .sink { [weak self] g in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.currentFEN = g.board.FEN
                }
            }
            .store(in: &cancellables)

        chessStore.gameAction(.startGame)
        Task { await engine.newGame() }
    }

    // MARK: - Pause / Resume
    //
    // Architecture (simplified from the previous player-swap approach):
    //
    // togglePause() only sets robotController.isPaused. The robot's evalutate()
    // thread polls this flag and blocks in waitForManualMoveOrResume() when true.
    //
    // To play a move for Leela, the user taps two squares on the board.
    // DaceloboardView detects this (because isPaused && isRobotsTurn) and calls
    // submitManualMove(from:to:), depositing the move into the RobotController.
    // The robot thread picks it up and returns it to the Chess library.

    func togglePause() {
        guard gameMode == .humanVsEngine else { return }
        isPaused.toggle()
        manualSelectIdx = nil

        if isPaused {
            robotController.isPaused = true
        } else {
            robotController.isPaused = false
            // Re-kick the game loop in case it's between moves.
            chessStore.gameAction(.startGame)
        }
    }

    // MARK: - Manual move for Leela
    //
    // Called from DaceloboardView when the user taps squares on Leela's behalf.
    // Uses a two-tap sequence tracked here so we can publish the selection index.

    func handleManualTap(boardIdx: Int) {
        guard isPaused, gameMode == .humanVsEngine else { return }

        if let from = manualSelectIdx {
            // Second tap — submit the move.
            manualSelectIdx = nil
            robotController.submitManualMove(from: from, to: boardIdx)
        } else {
            // First tap — record selection.
            manualSelectIdx = boardIdx
        }
    }

    // MARK: - Board Theme

    func setBoardTheme(_ theme: BoardTheme) {
        boardTheme = theme
        applyTheme(to: chessStore)
    }

    // MARK: - Position override (history navigation)

    /// Show a historical position on the board without affecting game state.
    /// The board becomes read-only while an override is active — no moves accepted.
    func showPosition(fen: String) {
        positionOverrideFEN = fen
        var game = Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        )
        game.board = Chess.Board(FEN: fen)
        let readOnly = ChessStore(game: game)
        applyTheme(to: readOnly)
        displayChessStore = readOnly
    }

    /// Return to the live game position, clearing any history override.
    func clearPositionOverride() {
        positionOverrideFEN = nil
        scratchChessStore   = nil
        displayChessStore   = chessStore
    }

    // MARK: - Helpers

    /// True when it is the Leela robot's turn to move.
    func isRobotsTurn() -> Bool {
        guard gameMode == .humanVsEngine else { return false }
        let parts = currentFEN.split(separator: " ")
        guard parts.count > 1 else { return false }
        let activeColor  = String(parts[1])
        let leelaIsBlack = playerColor == .white
        return leelaIsBlack ? activeColor == "b" : activeColor == "w"
    }
    
    /// Load a scratch game from a FEN so the user can explore freely.
    func beginScratchExploration(from fen: String) {
        var game = Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        )
        game.board = Chess.Board(FEN: fen)
        let store = ChessStore(game: game)
        applyTheme(to: store)
        store.gameAction(.startGame)
        scratchChessStore  = store
        displayChessStore  = store
    }
    
    /// Disregard scratch game
    func endScratchExploration() {
        scratchChessStore = nil
        // Return to the read-only history view if still reviewing, else live game
        if let fen = positionOverrideFEN {
            showPosition(fen: fen)   // rebuilds the read-only store into displayChessStore
        } else {
            displayChessStore = chessStore
        }
    }

    // MARK: - Private

    private func makePlayers() -> (Chess.Player, Chess.Player) {
        switch gameMode {
        case .humanVsEngine:
            let robot = makeRobot()
            return playerColor == .white
                ? (Chess.HumanPlayer(side: .white), robot)
                : (robot, Chess.HumanPlayer(side: .black))
        case .humanVsHuman, .analysisOnly:
            // Both modes use two human players. In analysisOnly the engine
            // analyses every move but does not generate moves itself.
            return (Chess.HumanPlayer(side: .white),
                    Chess.HumanPlayer(side: .black))
        }
    }

    private func makeRobot() -> UCIRobot {
        UCIRobot(
            side:            playerColor.opposite.chessSide,
            engine:          engine,
            moveTimeMs:      settings.moveTimeMs,
            bestMoveEngine:  settings.bestMoveEngine,
            robotController: robotController
        )
    }

    private func applyTheme(to store: ChessStore) {
        if let libColor = boardTheme.libraryColor {
            store.environmentChange(.boardColor(newColor: libColor))
        } else {
            store.environmentChange(.boardColor(newColor: .brown))
        }
    }
}
