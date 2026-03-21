// GameStore.swift
// Dacelo
//
// Manages the live chess game and scratch exploration.
// Built on ChessGame/ChessBoard — no swift-chess library dependency.
//
// Compared to the previous version:
//   - positionOverrideFEN, positionOverrideLastMove, scratchChessStore,
//     displayChessStore, displayBoardFEN, currentFEN, isReplayingMoves
//     all collapse into two published properties: reviewGame and scratchGame
//   - beginScratchExploration is three lines
//   - Both sides always playable in scratch — no library workarounds needed
//   - Robot loop is a clean async Task, no semaphore/Thread.sleep
//   - No Combine pipelines — GameStore owns all state directly

import SwiftUI

// MARK: - PlayerColor

enum PlayerColor: String, CaseIterable, Identifiable {
    case white = "White"
    case black = "Black"
    var id: String { rawValue }
    var opposite: PlayerColor { self == .white ? .black : .white }
    var side: Side { self == .white ? .white : .black }
}

// MARK: - GameMode

enum GameMode: String, CaseIterable, Identifiable {
    case humanVsEngine = "vs Engine"
    case humanVsHuman  = "Two Players"
    case analysisOnly  = "Analysis"
    var id: String { rawValue }
    var isAnalysis: Bool { self == .analysisOnly }
}

// MARK: - BoardTheme

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

    // MARK: - Published state

    @Published var game:         ChessGame   = ChessGame()
    @Published var gameMode:     GameMode    = .humanVsEngine
    @Published var playerColor:  PlayerColor = .white
    @Published var boardTheme:   BoardTheme  = .brown
    @Published var isPaused:     Bool        = false

    /// Non-nil while reviewing a historical position (read-only until tapped).
    @Published var reviewGame:   ChessGame?  = nil

    /// Non-nil while exploring a sideline from a historical position.
    @Published var scratchGame:  ChessGame?  = nil

    /// First-tap index for manual robot move (two-tap flow when paused).
    @Published var manualRobotSelectIdx: Int? = nil

    // MARK: - Computed display state

    /// The game the board currently renders — scratch > review > live.
    var displayGame: ChessGame {
        scratchGame ?? reviewGame ?? game
    }

    var isExploringScratch: Bool { scratchGame != nil }
    var isReviewingHistory: Bool { reviewGame  != nil }
    var displayFEN:         String { displayGame.board.fen }

    var isRobotsTurn: Bool {
        guard gameMode == .humanVsEngine else { return false }
        return game.board.activeSide == playerColor.opposite.side
    }

    // MARK: - Private

    private let engine:    EngineService
    private let settings:  AppSettings
    private var robot:     ChessRobot?
    private var robotTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: EngineService, settings: AppSettings) {
        self.engine   = engine
        self.settings = settings
        startNewGame()
    }

    // MARK: - New Game

    func newGame() {
        cancelRobot()
        reviewGame           = nil
        scratchGame          = nil
        isPaused             = false
        manualRobotSelectIdx = nil
        startNewGame()
        Task { await engine.newGame() }
    }

    private func startNewGame() {
        let chessMode: ChessGameMode = {
            switch gameMode {
            case .humanVsEngine: return .humanVsRobot(humanSide: playerColor.side)
            case .humanVsHuman:  return .humanVsHuman
            case .analysisOnly:  return .analysis
            }
        }()
        game = ChessGame(fen: ChessBoard.startingFEN, mode: chessMode)

        if gameMode == .humanVsEngine {
            robot = ChessRobot(
                side:           playerColor.opposite.side,
                engine:         engine,
                moveTimeMs:     settings.moveTimeMs,
                bestMoveEngine: settings.bestMoveEngine
            )
            kickRobotIfNeeded()
        } else {
            robot = nil
        }
    }

    // MARK: - Board interaction (called from BoardLayout)

    func handleTap(at index: Int) {
        // Manual robot move while paused.
        if isPaused && isRobotsTurn {
            handleManualRobotTap(at: index)
            return
        }

        if isExploringScratch {
            scratchGame?.handleTap(at: index)
        } else if isReviewingHistory {
            // First tap on a history position starts scratch exploration.
            beginScratchExploration()
            scratchGame?.handleTap(at: index)
        } else {
            let moved = game.handleTap(at: index) != nil
            if moved { kickRobotIfNeeded() }
        }
    }

    func handleDragStart(at index: Int) -> Bool {
        if isPaused && isRobotsTurn {
            return game.board.squares[index]?.side == playerColor.opposite.side
        }
        if isExploringScratch {
            return scratchGame?.handleDragStart(at: index) ?? false
        } else if isReviewingHistory {
            beginScratchExploration()
            return scratchGame?.handleDragStart(at: index) ?? false
        } else {
            return game.handleDragStart(at: index)
        }
    }

    func handleDrop(at index: Int) {
        if isPaused && isRobotsTurn {
            guard let from = manualRobotSelectIdx else { return }
            manualRobotSelectIdx = nil
            robot?.controller.submitManualMove(from: from, to: index)
            return
        }
        if isExploringScratch {
            scratchGame?.handleDrop(to: index)
        } else {
            let moved = game.handleDrop(to: index) != nil
            if moved { kickRobotIfNeeded() }
        }
    }

    // MARK: - History navigation

    func showHistoryPosition(fen: String) {
        scratchGame = nil   // always tear down scratch before navigating
        reviewGame  = ChessGame(fen: fen, mode: .analysis)
    }

    func clearHistoryReview() {
        scratchGame = nil
        reviewGame  = nil
    }

    // MARK: - Scratch exploration (three lines — no workarounds needed)

    func beginScratchExploration() {
        guard let review = reviewGame else { return }
        scratchGame = ChessGame.scratch(from: review.board.fen)
    }

    func endScratchExploration() {
        scratchGame = nil
    }

    // MARK: - Pause / manual robot

    func togglePause() {
        guard gameMode == .humanVsEngine else { return }
        isPaused.toggle()
        manualRobotSelectIdx = nil
        robot?.controller.isPaused = isPaused
        if !isPaused { kickRobotIfNeeded() }
    }

    private func handleManualRobotTap(at index: Int) {
        if let from = manualRobotSelectIdx {
            manualRobotSelectIdx = nil
            robot?.controller.submitManualMove(from: from, to: index)
        } else if game.board.squares[index]?.side == playerColor.opposite.side {
            manualRobotSelectIdx = index
        }
    }

    // MARK: - Board theme

    func setBoardTheme(_ theme: BoardTheme) {
        boardTheme = theme
    }

    // MARK: - Robot loop

    private func kickRobotIfNeeded() {
        guard gameMode == .humanVsEngine,
              !isPaused,
              isRobotsTurn,
              game.status == .active || game.status == .check,
              robotTask == nil,
              let robot
        else { return }

        let board = game.board  // capture value type — no await needed

        robotTask = Task { [weak self] in
            let result = await robot.think(board: board)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.robotTask = nil
                guard let result else { return }
                let applied = self.game.applyRobotMove(
                    from:      result.from,
                    to:        result.to,
                    promotion: result.promotion
                )
                if applied { self.kickRobotIfNeeded() }
            }
        }
    }

    private func cancelRobot() {
        robotTask?.cancel()
        robotTask = nil
        let r = robot
        robot = nil
        Task { await r?.cancel() }
    }
}
