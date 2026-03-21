// ChessGame.swift
// Dacelo
//
// Game state built on top of ChessBoard + ChessMoveGenerator.
// Owns the move history, handles turn sequencing, and exposes
// the minimal interface that GameStore needs.
//
// Design:
//   - Pure value type — copy freely for scratch exploration
//   - No Combine, no ObservableObject — GameStore owns publishing
//   - Move history stored as (ChessMove, ChessBoard) pairs so any
//     position can be restored instantly without replaying
//   - Robot moves delivered via async/await through a callback,
//     keeping ChessGame itself synchronous and actor-free

import Foundation

// MARK: - MoveRecord

/// One entry in the game's move history.
public struct MoveRecord: Identifiable {
    public let id:       UUID
    public let move:     ChessMove
    /// Board state AFTER this move was applied.
    public let board:    ChessBoard
    /// Board state BEFORE this move (for undo / navigation).
    public let previous: ChessBoard

    public init(move: ChessMove, board: ChessBoard, previous: ChessBoard) {
        self.id       = UUID()
        self.move     = move
        self.board    = board
        self.previous = previous
    }
}

// MARK: - GameMode

public enum ChessGameMode {
    case humanVsHuman
    case humanVsRobot(humanSide: Side)
    case analysis      // both sides human, full analysis, scratch exploration enabled
}

// MARK: - ChessGame

public struct ChessGame {

    // MARK: State

    public var board:   ChessBoard
    public var history: [MoveRecord] = []
    public var mode:    ChessGameMode = .humanVsHuman
    public var status:  GameStatus    = .active

    /// The square the user has tapped first (awaiting destination tap).
    public var selectedSquare: BoardIndex? = nil

    /// Legal destinations for the currently selected square (pip squares).
    public var legalDestinations: [BoardIndex] = []

    // MARK: Init

    public init(fen: String = ChessBoard.startingFEN, mode: ChessGameMode = .humanVsHuman) {
        self.board  = ChessBoard(fen: fen)
        self.mode   = mode
        self.status = ChessMoveGenerator.gameStatus(for: board)
    }

    // MARK: - Human interaction

    /// Handle a tap at `index`. Returns the move that was made (if any).
    ///
    /// Two-tap flow:
    ///   Tap 1 on own piece  → select, compute legal destinations
    ///   Tap 1 on empty/enemy → deselect
    ///   Tap 2 on destination → execute move, deselect
    ///   Tap 2 on another own piece → reselect
    @discardableResult
    public mutating func handleTap(at index: BoardIndex) -> ChessMove? {
        guard status == .active || status == .check else { return nil }

        // If a square is already selected:
        if let from = selectedSquare {
            // Tapping the same square deselects.
            if from == index {
                clearSelection()
                return nil
            }
            // Tapping a legal destination executes the move.
            if legalDestinations.contains(index) {
                return executeHumanMove(from: from, to: index)
            }
            // Tapping another own piece reselects.
            if board.squares[index]?.side == board.activeSide {
                select(index)
                return nil
            }
            // Tapping anything else deselects.
            clearSelection()
            return nil
        }

        // No square selected yet — select if own piece.
        if board.squares[index]?.side == board.activeSide {
            select(index)
        }
        return nil
    }

    /// Handle a drag start. Returns true if the piece can be dragged.
    public mutating func handleDragStart(at index: BoardIndex) -> Bool {
        guard board.squares[index]?.side == board.activeSide,
              status == .active || status == .check else { return false }
        select(index)
        return true
    }

    /// Handle a drag drop. Returns the move that was made (if any).
    @discardableResult
    public mutating func handleDrop(to index: BoardIndex) -> ChessMove? {
        guard let from = selectedSquare else { return nil }
        if legalDestinations.contains(index) {
            return executeHumanMove(from: from, to: index)
        }
        clearSelection()
        return nil
    }

    // MARK: - Robot move submission

    /// Apply a robot move (already validated by the engine's UCI output).
    /// Returns false if the move isn't legal (engine returned a bad move).
    @discardableResult
    public mutating func applyRobotMove(from: BoardIndex, to: BoardIndex, promotion: PieceType? = nil) -> Bool {
        let legal = ChessMoveGenerator.legalMoves(for: board)

        // Find the matching legal move (handles en passant and castling flags).
        guard let move = legal.first(where: {
            $0.from == from && $0.to == to &&
            ($0.promotion == promotion || promotion == nil)
        }) else {
            print("[ChessGame] Robot move \(ChessMove(from: from, to: to).uci) is not legal in position \(board.fen)")
            return false
        }

        applyMove(move)
        return true
    }

    // MARK: - Move application (shared)

    public mutating func applyMove(_ move: ChessMove) {
        let previous = board
        board.applyMove(move)
        history.append(MoveRecord(move: move, board: board, previous: previous))
        status = ChessMoveGenerator.gameStatus(for: board)
        clearSelection()
    }

    // MARK: - History navigation

    /// Board state after move at history index (0-based). Returns current if out of range.
    public func board(at historyIndex: Int) -> ChessBoard? {
        guard history.indices.contains(historyIndex) else { return nil }
        return history[historyIndex].board
    }

    /// Restore board state to after move at `historyIndex`. Clears future history.
    public mutating func jumpTo(historyIndex: Int) {
        guard let target = board(at: historyIndex) else { return }
        board  = target
        status = ChessMoveGenerator.gameStatus(for: board)
        clearSelection()
    }

    // MARK: - Active-side guard for drag permission

    /// Whether the human is allowed to interact with pieces at `index`.
    public func canInteract(at index: BoardIndex, humanSide: Side?) -> Bool {
        guard status == .active || status == .check else { return false }
        if let humanSide {
            // Human vs robot: only own pieces.
            return board.squares[index]?.side == humanSide
                   && board.activeSide == humanSide
        }
        // Human vs human / analysis: active side only.
        return board.squares[index]?.side == board.activeSide
    }

    // MARK: - Private

    private mutating func select(_ index: BoardIndex) {
        selectedSquare    = index
        legalDestinations = ChessMoveGenerator.legalDestinations(from: index, on: board)
    }

    private mutating func clearSelection() {
        selectedSquare    = nil
        legalDestinations = []
    }

    /// Execute a human move. Automatically promotes to queen unless the caller
    /// specifies otherwise (promotion UI can follow up with applyMove directly).
    private mutating func executeHumanMove(from: BoardIndex, to: BoardIndex) -> ChessMove? {
        let legal = ChessMoveGenerator.legalMoves(for: board)

        // Prefer the queen-promotion move if multiple promotions are available;
        // the UI can present a picker and call applyMove with a specific promotion.
        let move = legal
            .filter { $0.from == from && $0.to == to }
            .sorted { ($0.promotion == .queen ? 0 : 1) < ($1.promotion == .queen ? 0 : 1) }
            .first

        guard let move else { return nil }
        applyMove(move)
        return move
    }
}

// MARK: - Scratch exploration convenience

public extension ChessGame {

    /// Create a scratch game for exploring sidelines from a FEN.
    /// This is the canonical replacement for all the `beginScratchExploration`
    /// complexity — just init a new ChessGame from a FEN. Both sides are human,
    /// no state machine ceremony required.
    static func scratch(from fen: String) -> ChessGame {
        ChessGame(fen: fen, mode: .analysis)
    }
}
