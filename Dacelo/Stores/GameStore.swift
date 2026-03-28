// GameStore.swift
// Dacelo

import SwiftUI
import Combine

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

    @Published var game:                ChessGame   = ChessGame()
    @Published var gameMode:            GameMode    = .humanVsEngine
    @Published var playerColor:         PlayerColor = .white
    @Published var boardTheme:          BoardTheme  = .brown
    // isPaused removed — pause functionality removed
    @Published var reviewGame:          ChessGame?  = nil
    @Published var scratchGame:         ChessGame?  = nil
    @Published var manualRobotSelectIdx: Int?       = nil
    @Published var scratchHistoryIndex: Int?        = nil
    @Published var clock:               ChessClock  = ChessClock()

    // MARK: - Computed display state

    var displayGame: ChessGame { scratchGame ?? reviewGame ?? game }
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
<<<<<<< Updated upstream
    private var robotTask:    Task<Void, Never>?
    // Pondering state — the FEN after the robot's last move and the
    // predicted opponent reply (PV[1] from the engine's search).
    private var ponderFEN:    String? = nil
    private var ponderMove:   String? = nil
=======
    private var robotTask:  Task<Void, Never>?
    private var ponderMove: String? = nil  // predicted human reply after robot moves
>>>>>>> Stashed changes
    // Forwards ChessClock.objectWillChange into GameStore.objectWillChange so
    // ContentView (which observes GameStore) re-renders on every clock tick.
    private var clockCancellable: AnyCancellable?

    // MARK: - Init

    init(engine: EngineService, settings: AppSettings) {
        self.engine   = engine
        self.settings = settings
        startNewGame()
        // Bridge clock publisher — must happen after startNewGame sets up clock
        clockCancellable = clock.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - New Game

    func newGame() {
        cancelRobot()
        ponderMove           = nil
        reviewGame           = nil
        scratchGame          = nil
        scratchHistoryIndex  = nil
        manualRobotSelectIdx = nil
        startNewGame()
        Task {
            await engine.stopPonder()
            await engine.newGame()
        }
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

        // Configure clock from saved settings
        clock.configure(control: settings.timeControl, startingSide: .white)

        if gameMode == .humanVsEngine || gameMode == .humanVsHuman {
            clock.start()
        }

        if gameMode == .humanVsEngine {
            robot = ChessRobot(
                side:           playerColor.opposite.side,
                engine:         engine,
                moveTimeMs:     settings.moveTimeMs,
                bestMoveEngine: settings.bestMoveEngine,
                difficulty:     settings.difficulty,
                openingMoves:   settings.openingMovesDepth
            )
            Task { @MainActor in self.kickRobotIfNeeded() }
        } else {
            robot = nil
        }
    }

    // MARK: - Board interaction

    func handleTap(at index: Int) {
        if isExploringScratch {
            scratchGame?.handleTap(at: index)
        } else if isReviewingHistory {
            beginScratchExploration()
            scratchGame?.handleTap(at: index)
        } else {
            let side  = game.board.activeSide
            let moved = game.handleTap(at: index) != nil
            if moved {
                clock.switchTurn(movedSide: side)
<<<<<<< Updated upstream
                handleHumanMoveForPonder(playedUCI: game.history.last?.move.uci)
=======
                handleHumanMoved()
>>>>>>> Stashed changes
                kickRobotIfNeeded()
            }
        }
    }

    func handleDragStart(at index: Int) -> Bool {
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
        if isExploringScratch {
            scratchGame?.handleDrop(to: index)
        } else {
            let side  = game.board.activeSide
            let moved = game.handleDrop(to: index) != nil
            if moved {
                clock.switchTurn(movedSide: side)
<<<<<<< Updated upstream
                handleHumanMoveForPonder(playedUCI: game.history.last?.move.uci)
=======
                handleHumanMoved()
>>>>>>> Stashed changes
                kickRobotIfNeeded()
            }
        }
    }

    // MARK: - Ponder

    private func handleHumanMoveForPonder(playedUCI: String?) {
        guard let pm = ponderMove, ponderFEN != nil else { return }
        ponderMove = nil; ponderFEN = nil
        if let played = playedUCI, played == pm {
            pendingPonderHit = true
        } else {
            Task { [weak self] in
                guard let self else { return }
                await self.engine.stopPonder(engine: self.settings.bestMoveEngine)
            }
        }
    }

    private var pendingPonderHit: Bool    = false
    private var pendingPonderFEN: String? = nil

    // MARK: - History navigation

    func showHistoryPosition(fen: String) {
        scratchGame = nil
        reviewGame  = ChessGame(fen: fen, mode: .analysis)
    }

    func clearHistoryReview() {
        scratchGame = nil
        reviewGame  = nil
    }

    // MARK: - Scratch exploration

    func beginScratchExploration() {
        guard let review = reviewGame else { return }
        scratchGame         = ChessGame.scratch(from: review.board.fen)
        scratchHistoryIndex = nil
    }

    func endScratchExploration() {
        scratchGame         = nil
        scratchHistoryIndex = nil
    }

    func goBackInHistory() {
        if isExploringScratch, let scratch = scratchGame {
            let current = scratchHistoryIndex ?? (scratch.history.count - 1)
            let target  = current - 1
            if target < 0 {
                endScratchExploration()
            } else {
                scratchHistoryIndex = target
                reviewGame = ChessGame(fen: scratch.history[target].board.fen, mode: .analysis)
            }
        }
    }

    func goForwardInScratch() {
        guard isExploringScratch, let scratch = scratchGame else { return }
        let current = scratchHistoryIndex ?? (scratch.history.count - 1)
        let target  = current + 1
        if target >= scratch.history.count {
            scratchHistoryIndex = nil
            reviewGame          = nil
        } else {
            scratchHistoryIndex = target
            reviewGame = ChessGame(fen: scratch.history[target].board.fen, mode: .analysis)
        }
    }

    var canGoBackInScratch: Bool { isExploringScratch }
    var canGoForwardInScratch: Bool {
        guard isExploringScratch, let scratch = scratchGame else { return false }
        let current = scratchHistoryIndex ?? (scratch.history.count - 1)
        return current < scratch.history.count - 1
    }

    // Pause functionality removed

    // MARK: - Board theme

    func setBoardTheme(_ theme: BoardTheme) { boardTheme = theme }

    // MARK: - Captured pieces

    var capturedPieces: (white: [PieceType], black: [PieceType]) {
        var whiteCaptured: [PieceType] = []
        var blackCaptured: [PieceType] = []
        let source = scratchGame ?? game
        for record in source.history {
            let move     = record.move
            let previous = record.previous
            if let captured = previous.squares[move.to], captured.side != previous.activeSide {
                captured.side == .white ? whiteCaptured.append(captured.type)
                                        : blackCaptured.append(captured.type)
            }
            if move.isEnPassant {
                let idx = previous.activeSide == .white ? move.to + 8 : move.to - 8
                if let captured = previous.squares[idx] {
                    captured.side == .white ? whiteCaptured.append(captured.type)
                                            : blackCaptured.append(captured.type)
                }
            }
        }
        let order: [PieceType] = [.queen, .rook, .bishop, .knight, .pawn]
        let sort: ([PieceType]) -> [PieceType] = {
            $0.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        return (white: sort(whiteCaptured), black: sort(blackCaptured))
    }

    // MARK: - Ponder

    private func handleHumanMoved() {
        guard let pm = ponderMove else { return }
        let playedUCI = game.history.last?.move.uci
        ponderMove = nil
        let bme = settings.bestMoveEngine
        if playedUCI == pm {
            // Human played the predicted move — ponderhit
            pendingPonderHit = true
        } else {
            Task { await engine.stopPonder(engine: bme) }
        }
    }

    private var pendingPonderHit: Bool = false

    // MARK: - Robot loop

    private func kickRobotIfNeeded() {
        guard gameMode == .humanVsEngine,
              isRobotsTurn,
              game.status == .active || game.status == .check,
              robotTask == nil,
              let robot
        else { return }

<<<<<<< Updated upstream
        let board            = game.board
        let usePonderHit     = pendingPonderHit
        pendingPonderHit     = false
        pendingPonderFEN     = nil
        let bestMoveEngine   = settings.bestMoveEngine
        let moveTimeMs       = settings.moveTimeMs

        robotTask = Task { [weak self] in
            guard let self else { return }

            // If the human played the predicted move, cash in the ponder work
            let result: (from: BoardIndex, to: BoardIndex, promotion: PieceType?)?
            if usePonderHit {
                result = await robot.thinkWithPonderHit(
                    engine:         self.engine,
                    bestMoveEngine: bestMoveEngine,
                    moveTimeMs:     moveTimeMs
                )
            } else {
                result = await robot.think(board: board)
            }

            await MainActor.run { [weak self] in
                guard let self, let result else {
                    self?.robotTask = nil
                    return
                }
=======
        let board          = game.board
        let usePonderHit   = pendingPonderHit
        let currentFEN     = game.board.fen
        pendingPonderHit   = false
        let bme            = settings.bestMoveEngine
        let mt             = settings.moveTimeMs

        robotTask = Task { [weak self] in
            guard let self else { return }
            let result = await robot.think(board: board)
            await MainActor.run { [weak self] in
                guard let self, let result else { self?.robotTask = nil; return }
>>>>>>> Stashed changes
                self.robotTask = nil
                let robotSide = self.game.board.activeSide
                let applied   = self.game.applyRobotMove(
                    from: result.from, to: result.to, promotion: result.promotion)
                if applied {
                    self.clock.switchTurn(movedSide: robotSide)
<<<<<<< Updated upstream

                    // Fire ponder on the predicted human reply (PV[1])
                    // after the robot's move is applied.
                    // If the robot has a stored ponder candidate, use it.
                    if let pFen = robot.lastPonderFEN,
                       let pMove = robot.lastPonderMove {
                        self.ponderFEN  = pFen
                        self.ponderMove = pMove
                        Task {
                            await self.engine.ponder(
                                fen:        pFen,
                                ponderMove: pMove,
                                engine:     bestMoveEngine
                            )
                        }
                    }

=======
                    // Fire ponder on predicted human reply using post-move FEN
                    if let pm = robot.lastPonderMove {
                        let postFEN = self.game.board.fen
                        self.ponderMove = pm
                        Task { await self.engine.ponder(
                            fen: postFEN, ponderMove: pm, engine: bme) }
                    }
>>>>>>> Stashed changes
                    self.kickRobotIfNeeded()
                }
            }
        }
    }

    private func cancelRobot() {
        robotTask?.cancel()
        robotTask      = nil
        ponderMove     = nil
        pendingPonderHit = false
        let r = robot
        robot = nil
        Task {
            await self.engine.stopPonder()
            await r?.cancel()
        }
    }
}
