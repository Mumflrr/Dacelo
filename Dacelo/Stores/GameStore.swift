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
//
// Scratch sideline architecture:
//   beginScratchExploration() creates a fresh ChessStore from a historical FEN
//   and transitions it to "playing" via gameAction(.startGame). Moves are
//   accepted by the board but never recorded into moveCritiques.
//
//   Re-render bridge: BoardLayout only re-renders when a @Published property
//   on GameStore changes. displayBoardFEN is the single published String that
//   both the live-game sink and the scratch-game sink write to, giving
//   BoardLayout a reliable reactive signal after every accepted move.
//
//   Threading: ChessStore.$game publishes on a background thread (the library's
//   chess engine thread). Every sink that writes @Published properties MUST hop
//   to the main queue via .receive(on: DispatchQueue.main). gameAction() itself
//   is only ever called directly from @MainActor context.

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

    /// The single FEN string that BoardLayout observes for re-renders.
    ///
    /// Both the live-game Combine sink (in newGame()) and the scratch-game
    /// Combine sink (in beginScratchExploration()) write here — always on the
    /// main thread — so BoardLayout's onChange(of: gameStore.displayBoardFEN)
    /// fires reliably after every accepted move in either context.
    @Published var displayBoardFEN: String = ""

    /// When non-nil the board shows this FEN instead of the live game position.
    @Published var positionOverrideFEN: String? = nil
    /// The UCI string of the last move played to reach positionOverrideFEN.
    /// Used by beginScratchExploration to populate board.turns so
    /// computeGameStatus() returns .active instead of .unknown.
    @Published var positionOverrideLastMove: String? = nil

    /// The scratch ChessStore for sideline exploration. Nil outside exploration.
    /// AnalysisStore.observeScratch() watches this to detect when a new scratch
    /// game starts and re-subscribes to analyse scratch moves.
    @Published var scratchChessStore: ChessStore? = nil

    /// True while the user is in the middle of a two-tap manual move for Leela.
    @Published var manualSelectIdx: Int? = nil

    var displayFEN:         String { positionOverrideFEN ?? currentFEN }
    var isExploringScratch: Bool   { scratchChessStore != nil }

    /// The ChessStore the board renders. Always a stable @Published reference
    /// so @EnvironmentObject injection stays consistent across mode switches.
    @Published var displayChessStore: ChessStore = ChessStore(game: Chess.Game(
        Chess.HumanPlayer(side: .white),
        against: Chess.HumanPlayer(side: .black)
    ))

    // MARK: - Robot controller

    private(set) var robotController = RobotController()

    private let engine:   EngineService
    private let settings: AppSettings

    /// Subscriptions for the live game. Cleared and rebuilt in newGame().
    private var cancellables: Set<AnyCancellable> = []

    /// Subscription for the active scratch store's $game publisher.
    /// Kept separate so tearing it down never disturbs the live-game sink.
    private var scratchCancellables: Set<AnyCancellable> = []

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

        isPaused        = false
        manualSelectIdx = nil

        // Tear down ALL override/scratch state before replacing the live store.
        // positionOverrideFEN must be cleared here — if newGame() is called while
        // the user is browsing history, leaving it set means BoardLayout.handleTap
        // sees positionOverrideFEN != nil on the very first tap and re-enters
        // beginScratchExploration from the old historical FEN instead of passing
        // the move to the new live game.
        scratchCancellables.removeAll()
        scratchChessStore   = nil
        positionOverrideFEN = nil

        let (white, black) = makePlayers()
        let store = ChessStore(game: Chess.Game(white, against: black))
        applyTheme(to: store)
        chessStore        = store
        displayChessStore = store
        currentFEN        = store.game.board.FEN
        displayBoardFEN   = store.game.board.FEN

        cancellables.removeAll()

        // Bridge live-game FEN changes to displayBoardFEN and currentFEN.
        // .receive(on: DispatchQueue.main) is REQUIRED — ChessStore.$game
        // publishes on the chess-engine background thread.
        chessStore.$game
            .receive(on: DispatchQueue.main)
            .sink { [weak self] g in
                guard let self else { return }
                let fen = g.board.FEN
                self.currentFEN = fen
                // Only update displayBoardFEN from the live sink when no scratch
                // game is active — the scratch sink owns it during exploration.
                if self.scratchChessStore == nil {
                    self.displayBoardFEN = fen
                }
            }
            .store(in: &cancellables)

        chessStore.gameAction(.startGame)
        Task { await engine.newGame() }
    }

    // MARK: - Pause / Resume

    func togglePause() {
        guard gameMode == .humanVsEngine else { return }
        isPaused.toggle()
        manualSelectIdx = nil

        if isPaused {
            robotController.isPaused = true
        } else {
            robotController.isPaused = false
            chessStore.gameAction(.startGame)
        }
    }

    // MARK: - Manual move for Leela

    func handleManualTap(boardIdx: Int) {
        guard isPaused, gameMode == .humanVsEngine else { return }

        if let from = manualSelectIdx {
            manualSelectIdx = nil
            robotController.submitManualMove(from: from, to: boardIdx)
        } else {
            manualSelectIdx = boardIdx
        }
    }

    // MARK: - Board Theme

    func setBoardTheme(_ theme: BoardTheme) {
        boardTheme = theme
        applyTheme(to: chessStore)
    }

    // MARK: - Position override (history navigation)

    func showPosition(fen: String, lastMove: String? = nil) {
        positionOverrideFEN      = fen
        positionOverrideLastMove = lastMove
        displayBoardFEN          = fen
        var game = Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        )
        game.board = Chess.Board(FEN: fen)
        let readOnly = ChessStore(game: game)
        applyTheme(to: readOnly)
        displayChessStore = readOnly
    }

    // MARK: - Scratch sideline exploration

    @Published var isReplayingMoves: Bool = false  // kept for BoardLayout guard; always false

    /// Begin sideline exploration from a historical position.
    ///
    /// The correct approach is simply: construct a Game with the target FEN
    /// already set on its board, then wrap it in a ChessStore.
    ///
    /// ChessStore.init() does two things relevant here:
    ///   1. Preserves a pre-populated board — it only calls resetBoard() if
    ///      squares are empty, so our FEN position survives intact.
    ///   2. Sets game.delegate = self, wiring processGameChanges so the store
    ///      responds to userTappedSquare/userDropped normally.
    ///
    /// We do NOT call gameAction(.startGame). That action exists only to kick
    /// off a robot's turn-polling loop. For human vs human, HumanPlayer responds
    /// directly to user actions — no prior "start" call is needed or wanted.
    /// Calling it would spawn a background Task (causing the Thread Performance
    /// Checker warning) and set userPaused=true, blocking the first move.
    func beginScratchExploration(targetFEN: String, lastMove: String? = nil) {
        scratchCancellables.removeAll()

        var game = Chess.Game(
            Chess.HumanPlayer(side: .white),
            against: Chess.HumanPlayer(side: .black)
        )
        game.board = Chess.Board(FEN: targetFEN, populateExpensiveVisuals: true)

        // computeGameStatus() returns .unknown (blocking all taps) when
        // board.lastMove is nil — i.e. board.turns is empty. We must populate
        // turns with the real last move so the status resolves to .active.
        if let uci = lastMove, uci.count >= 4 {
            let fromStr = String(uci.prefix(2))
            let toStr   = String(uci.dropFirst(2).prefix(2))
            let from    = Chess.Position.from(rankAndFile: fromStr)
            let to      = Chess.Position.from(rankAndFile: toStr)
            let fenParts   = targetFEN.split(separator: " ")
            let activeSide = fenParts.count > 1 && fenParts[1] == "b" ? Chess.Side.white : Chess.Side.black
            let move = Chess.Move(side: activeSide, start: from, end: to)
            game.appendLedger(move, pieceType: .pawn, captureType: nil)
        }

        let store = ChessStore(game: game)
        applyTheme(to: store)
        store.gameAction(.startGame)
        applyTheme(to: store)

        scratchChessStore = store
        displayChessStore = store
        displayBoardFEN   = targetFEN

        store.$game
            .receive(on: DispatchQueue.main)
            .map { $0.board.FEN }
            .removeDuplicates()
            .sink { [weak self] newFEN in
                guard let self, self.scratchChessStore != nil else { return }
                self.displayBoardFEN = newFEN
            }
            .store(in: &scratchCancellables)
    }

    func clearPositionOverride() {
        print("CLEAR POSITION OVERRIDE called from: \(Thread.callStackSymbols[1])")
        scratchCancellables.removeAll()
        positionOverrideFEN      = nil
        positionOverrideLastMove = nil
        scratchChessStore        = nil
        displayChessStore        = chessStore
        displayBoardFEN          = currentFEN
    }

    func endScratchExploration() {
        print("END SCRATCH called from: \(Thread.callStackSymbols[1])")
        scratchCancellables.removeAll()
        scratchChessStore = nil
        if let fen = positionOverrideFEN {
            showPosition(fen: fen)
        } else {
            displayChessStore = chessStore
            displayBoardFEN   = currentFEN
        }
    }

    // MARK: - Helpers

    func isRobotsTurn() -> Bool {
        guard gameMode == .humanVsEngine else { return false }
        let parts = currentFEN.split(separator: " ")
        guard parts.count > 1 else { return false }
        let activeColor  = String(parts[1])
        let leelaIsBlack = playerColor == .white
        return leelaIsBlack ? activeColor == "b" : activeColor == "w"
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
