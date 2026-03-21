// ChessBoard.swift
// Dacelo
//
// Complete chess board model — replaces the swift-chess library dependency.
//
// Design principles:
//   - Value types throughout (structs) — safe to copy for legal-move checking
//   - BoardIndex is just Int (0-63), matching the existing library convention
//     so BoardArrowOverlay, UCIRobot, and AnalysisStore need minimal changes
//   - FEN is the single source of truth — parse in, serialize out
//   - No game state here (history, turn count) — that lives in ChessGame
//
// Coordinate system (matches swift-chess library):
//   index 0  = a8 (rank 8, file a) — top-left
//   index 63 = h1 (rank 1, file h) — bottom-right
//   index    = (8 - rank) * 8 + fileNumber   (fileNumber: a=0 … h=7)
//
//   rank = 8 - (index / 8)     (1–8)
//   file = index % 8           (0–7, a–h)

import Foundation
import SwiftUI

// MARK: - Side

public enum Side: String, Hashable, Codable, CaseIterable {
    case white = "w"
    case black = "b"

    public var opposite: Side { self == .white ? .black : .white }

    /// Rank direction for pawns: white advances to higher ranks (+1), black to lower (-1).
    var pawnDirection: Int { self == .white ? 1 : -1 }
    var pawnStartRank: Int { self == .white ? 2 : 7 }
    var pawnPromotionRank: Int { self == .white ? 8 : 1 }
}

// MARK: - PieceType

public enum PieceType: String, Hashable, Codable, CaseIterable {
    case pawn   = "p"
    case knight = "n"
    case bishop = "b"
    case rook   = "r"
    case queen  = "q"
    case king   = "k"

    /// Approximate material value in centipawns (for UI display only).
    var value: Int {
        switch self {
        case .pawn:   return 100
        case .knight: return 320
        case .bishop: return 330
        case .rook:   return 500
        case .queen:  return 900
        case .king:   return 0
        }
    }
}

// MARK: - Piece

public struct Piece: Hashable, Codable {
    public let side: Side
    public let type: PieceType

    /// FEN character: uppercase = white, lowercase = black.
    public var fenChar: Character {
        side == .white
            ? Character(type.rawValue.uppercased())
            : Character(type.rawValue)
    }

    /// Parse a single FEN character into a Piece.
    public static func from(fenChar: Character) -> Piece? {
        let lower = String(fenChar).lowercased()
        guard let type = PieceType(rawValue: lower) else { return nil }
        return Piece(side: fenChar.isUppercase ? .white : .black, type: type)
    }
}

// MARK: - BoardIndex
//
// typealias so call sites can use BoardIndex for clarity while the Int
// compatibility with existing code (BoardArrowOverlay, UCIRobot) is preserved.

public typealias BoardIndex = Int

public extension BoardIndex {

    /// Rank 1–8. Rank 8 is the top of the board (index 0–7).
    var rank: Int { 8 - (self / 8) }

    /// File 0–7 (a–h).
    var file: Int { self % 8 }

    /// File character 'a'–'h'.
    var fileChar: Character {
        "abcdefgh".map { $0 }[self % 8]
    }

    /// Algebraic notation e.g. "e4".
    var algebraic: String { "\(fileChar)\(rank)" }

    var isValid: Bool { self >= 0 && self <= 63 }

    static func from(rank: Int, file: Int) -> BoardIndex {
        (8 - rank) * 8 + file
    }

    /// Parse algebraic notation ("e4") → BoardIndex. Returns nil on bad input.
    static func from(algebraic: String) -> BoardIndex? {
        let s = algebraic.lowercased()
        guard s.count >= 2 else { return nil }
        let chars = Array(s)
        guard let fileIdx = "abcdefgh".firstIndex(of: chars[0]),
              let rankNum = Int(String(chars[1])),
              (1...8).contains(rankNum) else { return nil }
        let file = "abcdefgh".distance(from: "abcdefgh".startIndex, to: fileIdx)
        return from(rank: rankNum, file: file)
    }
}

// MARK: - CastlingRights

public struct CastlingRights: Hashable, Codable {
    public var whiteKingSide:  Bool = true
    public var whiteQueenSide: Bool = true
    public var blackKingSide:  Bool = true
    public var blackQueenSide: Bool = true

    public var fenString: String {
        var s = ""
        if whiteKingSide  { s += "K" }
        if whiteQueenSide { s += "Q" }
        if blackKingSide  { s += "k" }
        if blackQueenSide { s += "q" }
        return s.isEmpty ? "-" : s
    }

    public mutating func parse(_ s: String) {
        whiteKingSide  = s.contains("K")
        whiteQueenSide = s.contains("Q")
        blackKingSide  = s.contains("k")
        blackQueenSide = s.contains("q")
    }

    public func canCastle(kingSide: Bool, for side: Side) -> Bool {
        switch (side, kingSide) {
        case (.white, true):  return whiteKingSide
        case (.white, false): return whiteQueenSide
        case (.black, true):  return blackKingSide
        case (.black, false): return blackQueenSide
        }
    }
}

// MARK: - ChessMove

public struct ChessMove: Hashable {
    public let from:        BoardIndex
    public let to:          BoardIndex
    public let promotion:   PieceType?     // non-nil only for pawn promotions
    public let isEnPassant: Bool
    public let castling:    CastlingSide?

    public enum CastlingSide: Hashable { case kingSide, queenSide }

    public init(
        from:        BoardIndex,
        to:          BoardIndex,
        promotion:   PieceType?   = nil,
        isEnPassant: Bool         = false,
        castling:    CastlingSide? = nil
    ) {
        self.from        = from
        self.to          = to
        self.promotion   = promotion
        self.isEnPassant = isEnPassant
        self.castling    = castling
    }

    /// UCI string e.g. "e2e4", "e7e8q" for promotion.
    public var uci: String {
        let base = "\(from.algebraic)\(to.algebraic)"
        return promotion.map { base + $0.rawValue } ?? base
    }

    /// Parse a UCI string into a ChessMove. Promotion piece is inferred from length.
    public static func from(uci: String) -> ChessMove? {
        let s = uci.lowercased()
        guard s.count >= 4 else { return nil }
        guard let from = BoardIndex.from(algebraic: String(s.prefix(2))),
              let to   = BoardIndex.from(algebraic: String(s.dropFirst(2).prefix(2)))
        else { return nil }
        let promo = s.count > 4 ? PieceType(rawValue: String(s.suffix(1))) : nil
        return ChessMove(from: from, to: to, promotion: promo)
    }
}

// MARK: - ChessBoard

/// Immutable-ish board state. Use `applying(_:)` to get a new board after a move,
/// or `applyMove(_:)` to mutate in place (for the live game).
public struct ChessBoard: Hashable, Codable {

    // MARK: State

    /// 64 squares, index 0 = a8. nil = empty.
    public var squares:        [Piece?]
    public var activeSide:     Side           = .white
    public var castling:       CastlingRights = CastlingRights()
    /// The square a capturing pawn would land on for en passant. nil if unavailable.
    public var enPassantIndex: BoardIndex?    = nil
    /// Plies since last pawn move or capture (50-move rule).
    public var halfMoveClock:  Int            = 0
    /// Increments after black's move.
    public var fullMoveNumber: Int            = 1

    // MARK: Constants

    public static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    // MARK: Init

    public init() {
        squares = Array(repeating: nil, count: 64)
    }

    public init(fen: String) {
        squares = Array(repeating: nil, count: 64)
        parseFEN(fen)
    }

    // MARK: FEN parsing

    public mutating func parseFEN(_ fen: String) {
        squares = Array(repeating: nil, count: 64)
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return }

        // 1. Piece placement — iterate ranks 8→1, files a→h
        var index = 0
        for char in parts[0] {
            if char == "/" { continue }
            if let skip = char.wholeNumberValue {
                index += skip
            } else if let piece = Piece.from(fenChar: char), index < 64 {
                squares[index] = piece
                index += 1
            }
        }

        // 2. Active side
        if parts.count > 1 { activeSide = parts[1] == "b" ? .black : .white }

        // 3. Castling rights
        if parts.count > 2 { castling.parse(parts[2]) }

        // 4. En passant target square
        enPassantIndex = parts.count > 3 && parts[3] != "-"
            ? BoardIndex.from(algebraic: parts[3])
            : nil

        // 5. Clocks
        if parts.count > 4 { halfMoveClock  = Int(parts[4]) ?? 0 }
        if parts.count > 5 { fullMoveNumber = Int(parts[5]) ?? 1 }
    }

    // MARK: FEN serialization

    public var fen: String {
        var result = ""

        // Piece placement — ranks 8→1
        for rank in stride(from: 8, through: 1, by: -1) {
            var empty = 0
            for file in 0..<8 {
                let idx = BoardIndex.from(rank: rank, file: file)
                if let piece = squares[idx] {
                    if empty > 0 { result += "\(empty)"; empty = 0 }
                    result.append(piece.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { result += "\(empty)" }
            if rank > 1  { result += "/" }
        }

        result += " \(activeSide.rawValue)"
        result += " \(castling.fenString)"
        result += " \(enPassantIndex.map { $0.algebraic } ?? "-")"
        result += " \(halfMoveClock)"
        result += " \(fullMoveNumber)"
        return result
    }

    // MARK: Piece access

    public func piece(at index: BoardIndex) -> Piece? {
        index.isValid ? squares[index] : nil
    }

    public func kingIndex(for side: Side) -> BoardIndex? {
        squares.indices.first { squares[$0]?.type == .king && squares[$0]?.side == side }
    }

    // MARK: Move execution

    /// Returns a new board with the move applied. The caller is responsible for
    /// ensuring the move is legal. Use ChessMoveGenerator.legalMoves first.
    public func applying(_ move: ChessMove) -> ChessBoard {
        var board = self
        board.applyMove(move)
        return board
    }

    public mutating func applyMove(_ move: ChessMove) {
        guard let piece = squares[move.from] else { return }

        // Capture detection must happen before we overwrite move.to.
        let isCapture = squares[move.to] != nil || move.isEnPassant

        // En passant: remove the captured pawn from its actual square.
        // The capturing pawn lands at move.to (the en passant target);
        // the captured pawn sits one rank behind that target.
        if move.isEnPassant {
            let capturedPawnIdx = activeSide == .white ? move.to + 8 : move.to - 8
            squares[capturedPawnIdx] = nil
        }

        // Castling: move the rook alongside the king.
        switch move.castling {
        case .kingSide:
            let rookFrom = activeSide == .white ? 63 : 7
            let rookTo   = activeSide == .white ? 61 : 5
            squares[rookTo]   = squares[rookFrom]
            squares[rookFrom] = nil
        case .queenSide:
            let rookFrom = activeSide == .white ? 56 : 0
            let rookTo   = activeSide == .white ? 59 : 3
            squares[rookTo]   = squares[rookFrom]
            squares[rookFrom] = nil
        case nil:
            break
        }

        // Move the piece (apply promotion if present).
        squares[move.from] = nil
        squares[move.to]   = move.promotion.map { Piece(side: piece.side, type: $0) } ?? piece

        // Update castling rights based on king/rook movement or capture.
        updateCastlingRights(move: move)

        // En passant availability for next move: only set on double pawn push.
        if piece.type == .pawn && abs(move.from - move.to) == 16 {
            enPassantIndex = (move.from + move.to) / 2
        } else {
            enPassantIndex = nil
        }

        // 50-move rule clock.
        halfMoveClock = (piece.type == .pawn || isCapture) ? 0 : halfMoveClock + 1

        // Full move counter increments after black's move.
        if activeSide == .black { fullMoveNumber += 1 }

        activeSide = activeSide.opposite
    }

    // MARK: - Private helpers

    private mutating func updateCastlingRights(move: ChessMove) {
        // King moves — forfeit both sides.
        switch move.from {
        case 60: castling.whiteKingSide = false; castling.whiteQueenSide = false   // e1
        case 4:  castling.blackKingSide = false; castling.blackQueenSide = false   // e8
        default: break
        }
        // Rook moves from starting square.
        switch move.from {
        case 63: castling.whiteKingSide  = false   // h1
        case 56: castling.whiteQueenSide = false   // a1
        case 7:  castling.blackKingSide  = false   // h8
        case 0:  castling.blackQueenSide = false   // a8
        default: break
        }
        // Rook captured on starting square.
        switch move.to {
        case 63: castling.whiteKingSide  = false
        case 56: castling.whiteQueenSide = false
        case 7:  castling.blackKingSide  = false
        case 0:  castling.blackQueenSide = false
        default: break
        }
    }
}
