// ChessMoveGenerator.swift
// Dacelo
//
// Legal move generation for all piece types.
//
// Architecture:
//   pseudoLegalMoves  — fast, generates all moves ignoring check
//   legalMoves        — filters pseudolegal moves that leave own king in check
//   isInCheck         — detects check for a given side
//   isAttacked        — used by check detection and castling validation
//
// Performance:
//   Generating legal moves applies each pseudolegal move to a board copy and
//   calls isAttacked on the resulting position. This is O(moves × pieces) per
//   call — fast enough for interactive use. No bitboards needed at this scale.
//
// Special moves handled:
//   - Castling (both sides, both colours) with correct through-check detection
//   - En passant capture
//   - Pawn promotion (all four pieces)
//   - Pin detection (via board copy + check test, not explicit ray casting)

import Foundation

// MARK: - GameStatus

public enum GameStatus: Equatable {
    case active
    case check
    case checkmate
    case stalemate
    case drawByFiftyMoves
}

// MARK: - ChessMoveGenerator

public struct ChessMoveGenerator {

    // MARK: - Public API

    /// All legal moves for the active side. Filters out moves that leave the
    /// active side's king in check.
    public static func legalMoves(for board: ChessBoard) -> [ChessMove] {
        pseudoLegalMoves(for: board).filter { isLegal($0, on: board) }
    }

    /// Legal moves from a single square. Returns empty if no friendly piece
    /// is there or no legal moves are available.
    public static func legalMoves(from index: BoardIndex, on board: ChessBoard) -> [ChessMove] {
        guard let piece = board.squares[index], piece.side == board.activeSide else { return [] }
        return pseudoLegalMovesFrom(index, piece: piece, on: board).filter { isLegal($0, on: board) }
    }

    /// Returns the legal destination indices from a square (for pip rendering).
    public static func legalDestinations(from index: BoardIndex, on board: ChessBoard) -> [BoardIndex] {
        legalMoves(from: index, on: board).map { $0.to }
    }

    /// True if the given side's king is currently in check.
    public static func isInCheck(_ board: ChessBoard, side: Side) -> Bool {
        guard let kingIdx = board.kingIndex(for: side) else { return false }
        return isAttacked(kingIdx, by: side.opposite, on: board)
    }

    /// True if any square at `index` is attacked by any piece of `side`.
    public static func isAttacked(_ index: BoardIndex, by side: Side, on board: ChessBoard) -> Bool {
        for i in 0..<64 {
            guard let piece = board.squares[i], piece.side == side else { continue }
            // Use forAttackOnly=true for pawns so we get diagonal attack squares
            // even when they're empty (pawn captures vs pawn moves differ).
            if pseudoLegalMovesFrom(i, piece: piece, on: board, forAttackOnly: true)
                .contains(where: { $0.to == index }) {
                return true
            }
        }
        return false
    }

    /// Full game status for the active side.
    public static func gameStatus(for board: ChessBoard) -> GameStatus {
        if board.halfMoveClock >= 100 { return .drawByFiftyMoves }
        let inCheck = isInCheck(board, side: board.activeSide)
        let hasMoves = !legalMoves(for: board).isEmpty
        if !hasMoves { return inCheck ? .checkmate : .stalemate }
        return inCheck ? .check : .active
    }

    // MARK: - Move legality

    private static func isLegal(_ move: ChessMove, on board: ChessBoard) -> Bool {
        let after = board.applying(move)
        // The side that just moved must not be in check after the move.
        return !isInCheck(after, side: board.activeSide)
    }

    // MARK: - Pseudo-legal move generation

    static func pseudoLegalMoves(for board: ChessBoard) -> [ChessMove] {
        var moves: [ChessMove] = []
        moves.reserveCapacity(64)
        for i in 0..<64 {
            guard let piece = board.squares[i], piece.side == board.activeSide else { continue }
            moves += pseudoLegalMovesFrom(i, piece: piece, on: board)
        }
        return moves
    }

    static func pseudoLegalMovesFrom(
        _ index: BoardIndex,
        piece: Piece,
        on board: ChessBoard,
        forAttackOnly: Bool = false
    ) -> [ChessMove] {
        switch piece.type {
        case .pawn:   return pawnMoves(from: index, side: piece.side, on: board, forAttackOnly: forAttackOnly)
        case .knight: return jumpMoves(from: index, side: piece.side, on: board, offsets: knightOffsets)
        case .bishop: return slidingMoves(from: index, side: piece.side, on: board, directions: bishopDirs)
        case .rook:   return slidingMoves(from: index, side: piece.side, on: board, directions: rookDirs)
        case .queen:  return slidingMoves(from: index, side: piece.side, on: board, directions: queenDirs)
        case .king:   return kingMoves(from: index, side: piece.side, on: board, forAttackOnly: forAttackOnly)
        }
    }

    // MARK: - Direction tables

    private static let bishopDirs: [(Int, Int)] = [(-1,-1),(-1,1),(1,-1),(1,1)]
    private static let rookDirs:   [(Int, Int)] = [(-1,0),(1,0),(0,-1),(0,1)]
    private static let queenDirs:  [(Int, Int)] = [(-1,-1),(-1,1),(1,-1),(1,1),(-1,0),(1,0),(0,-1),(0,1)]
    private static let knightOffsets: [(Int,Int)] = [(-2,-1),(-2,1),(-1,-2),(-1,2),(1,-2),(1,2),(2,-1),(2,1)]
    private static let kingOffsets:   [(Int,Int)] = [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)]

    // MARK: - Sliding pieces (bishop, rook, queen)

    private static func slidingMoves(
        from index: BoardIndex,
        side: Side,
        on board: ChessBoard,
        directions: [(Int, Int)]
    ) -> [ChessMove] {
        var moves: [ChessMove] = []
        let startRank = index.rank
        let startFile = index.file

        for (dr, df) in directions {
            var rank = startRank + dr
            var file = startFile + df
            while (1...8).contains(rank) && (0...7).contains(file) {
                let target = BoardIndex.from(rank: rank, file: file)
                if let occupant = board.squares[target] {
                    // Can capture enemy pieces; can't pass through any piece.
                    if occupant.side != side { moves.append(ChessMove(from: index, to: target)) }
                    break
                }
                moves.append(ChessMove(from: index, to: target))
                rank += dr
                file += df
            }
        }
        return moves
    }

    // MARK: - Knight (and other jump pieces)

    private static func jumpMoves(
        from index: BoardIndex,
        side: Side,
        on board: ChessBoard,
        offsets: [(Int, Int)]
    ) -> [ChessMove] {
        let rank = index.rank
        let file = index.file
        return offsets.compactMap { (dr, df) in
            let r = rank + dr, f = file + df
            guard (1...8).contains(r), (0...7).contains(f) else { return nil }
            let target = BoardIndex.from(rank: r, file: f)
            if board.squares[target]?.side == side { return nil }   // can't capture own piece
            return ChessMove(from: index, to: target)
        }
    }

    // MARK: - Pawn

    private static func pawnMoves(
        from index: BoardIndex,
        side: Side,
        on board: ChessBoard,
        forAttackOnly: Bool
    ) -> [ChessMove] {
        var moves: [ChessMove] = []
        let rank      = index.rank
        let file      = index.file
        let dir       = side.pawnDirection       // +1 for white, -1 for black
        let promoRank = side.pawnPromotionRank   // 8 for white, 1 for black
        let nextRank  = rank + dir

        guard (1...8).contains(nextRank) else { return moves }

        // ── Diagonal attacks ──────────────────────────────────────────────
        // Always generated for forAttackOnly mode (check detection).
        // In normal mode, only generated when a capture or en passant is available.
        for df in [-1, 1] {
            let f = file + df
            guard (0...7).contains(f) else { continue }
            let target = BoardIndex.from(rank: nextRank, file: f)

            if forAttackOnly {
                moves.append(ChessMove(from: index, to: target))
            } else if let occupant = board.squares[target], occupant.side != side {
                // Normal diagonal capture — with promotion if reaching back rank.
                moves += nextRank == promoRank
                    ? promotionMoves(from: index, to: target)
                    : [ChessMove(from: index, to: target)]
            } else if board.enPassantIndex == target {
                moves.append(ChessMove(from: index, to: target, isEnPassant: true))
            }
        }

        if forAttackOnly { return moves }

        // ── Forward moves ─────────────────────────────────────────────────
        let oneForward = BoardIndex.from(rank: nextRank, file: file)
        guard board.squares[oneForward] == nil else { return moves }

        if nextRank == promoRank {
            moves += promotionMoves(from: index, to: oneForward)
        } else {
            moves.append(ChessMove(from: index, to: oneForward))

            // Double push from starting rank (both squares must be empty).
            if rank == side.pawnStartRank {
                let twoForward = BoardIndex.from(rank: rank + dir * 2, file: file)
                if board.squares[twoForward] == nil {
                    moves.append(ChessMove(from: index, to: twoForward))
                }
            }
        }

        return moves
    }

    private static func promotionMoves(from: BoardIndex, to: BoardIndex) -> [ChessMove] {
        [.queen, .rook, .bishop, .knight].map {
            ChessMove(from: from, to: to, promotion: $0)
        }
    }

    // MARK: - King

    private static func kingMoves(
        from index: BoardIndex,
        side: Side,
        on board: ChessBoard,
        forAttackOnly: Bool
    ) -> [ChessMove] {
        var moves: [ChessMove] = []

        // Normal one-square moves.
        for (dr, df) in kingOffsets {
            let r = index.rank + dr, f = index.file + df
            guard (1...8).contains(r), (0...7).contains(f) else { continue }
            let target = BoardIndex.from(rank: r, file: f)
            if board.squares[target]?.side == side { continue }
            moves.append(ChessMove(from: index, to: target))
        }

        // Castling — skip for attack detection (we only need square coverage).
        if forAttackOnly { return moves }

        let backRank   = side == .white ? 1 : 8
        let kingStart  = BoardIndex.from(rank: backRank, file: 4)   // e1 / e8
        guard index == kingStart, !isInCheck(board, side: side) else { return moves }

        // King-side castling: king e→g, squares f and g must be empty and unattacked.
        if board.castling.canCastle(kingSide: true, for: side) {
            let f1 = BoardIndex.from(rank: backRank, file: 5)   // f1/f8
            let g1 = BoardIndex.from(rank: backRank, file: 6)   // g1/g8
            // Rook must actually be present (handles FEN-loaded positions).
            let rookIdx = BoardIndex.from(rank: backRank, file: 7)
            if board.squares[f1] == nil,
               board.squares[g1] == nil,
               board.squares[rookIdx]?.type == .rook,
               board.squares[rookIdx]?.side == side,
               !isAttacked(f1, by: side.opposite, on: board),
               !isAttacked(g1, by: side.opposite, on: board) {
                moves.append(ChessMove(from: index, to: g1, castling: .kingSide))
            }
        }

        // Queen-side castling: king e→c, squares b, c, d must be empty;
        // c and d must be unattacked (b is not on king's path).
        if board.castling.canCastle(kingSide: false, for: side) {
            let d1 = BoardIndex.from(rank: backRank, file: 3)   // d1/d8
            let c1 = BoardIndex.from(rank: backRank, file: 2)   // c1/c8
            let b1 = BoardIndex.from(rank: backRank, file: 1)   // b1/b8
            let rookIdx = BoardIndex.from(rank: backRank, file: 0)
            if board.squares[d1] == nil,
               board.squares[c1] == nil,
               board.squares[b1] == nil,
               board.squares[rookIdx]?.type == .rook,
               board.squares[rookIdx]?.side == side,
               !isAttacked(d1, by: side.opposite, on: board),
               !isAttacked(c1, by: side.opposite, on: board) {
                moves.append(ChessMove(from: index, to: c1, castling: .queenSide))
            }
        }

        return moves
    }
}
