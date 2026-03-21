// BoardLayout.swift
// Dacelo
//
// Chess board UI built on ChessGame/ChessBoard.
//
// Compared to the previous version:
//   - No ChessStore, no ChessLibrary imports
//   - Both sides work identically — no white-only tap workaround
//   - Scratch exploration just works — no special black-tap handler
//   - Selection and pip highlights driven directly by ChessGame.selectedSquare
//     and ChessGame.legalDestinations — no library square.selected flags
//   - Drag state clears reliably via onChange(of: gameStore.displayFEN)
//   - canDragPiece is one simple expression

import SwiftUI

// MARK: - BoardLayout

struct BoardLayout: View {
    @EnvironmentObject var gameStore: GameStore
    let boardTheme: BoardTheme
    let pieceSet:   PieceSet
    let isFlipped:  Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)

    @State private var draggingFromVisualIdx: Int?    = nil
    @State private var dragOffset:            CGSize  = .zero
    @State private var isDropping:            Bool    = false

    private var display: ChessGame { gameStore.displayGame }

    var body: some View {
        // Reading displayFEN registers a SwiftUI dependency so the board
        // re-renders after every move in live, review, and scratch mode.
        let _ = gameStore.displayFEN

        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let sqSz = side / 8

            ZStack {
                // ── Grid ──────────────────────────────────────────────
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(0..<64) { visualIdx in
                        let bIdx = boardIndex(visualIdx)
                        squareView(bIdx: bIdx, sqSz: sqSz, visualIdx: visualIdx)
                            .frame(width: sqSz, height: sqSz)
                            .contentShape(Rectangle())
                            .onTapGesture { gameStore.handleTap(at: bIdx) }
                    }
                }
                .frame(width: side, height: side)

                // ── Floating piece during drag ────────────────────────
                if let fromVisual = draggingFromVisualIdx,
                   let piece = display.board.squares[boardIndex(fromVisual)] {
                    pieceImage(piece)
                        .frame(width: sqSz * 1.15, height: sqSz * 1.15)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .offset(dragOffset)
                        .position(squareCenter(visualIdx: fromVisual, sqSz: sqSz))
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .frame(width: side, height: side)
            .gesture(dragGesture(sqSz: sqSz))
            .onChange(of: gameStore.displayFEN) { _, _ in
                withAnimation(.easeOut(duration: 0.08)) {
                    draggingFromVisualIdx = nil
                    dragOffset            = .zero
                }
                isDropping = false
            }
        }
    }

    // MARK: - Square view

    @ViewBuilder
    private func squareView(bIdx: Int, sqSz: CGFloat, visualIdx: Int) -> some View {
        ZStack {
            // Background colour
            squareColor(bIdx)

            // Selection highlight (first tap)
            if display.selectedSquare == bIdx {
                Color.yellow.opacity(0.45)
            }

            // Legal destination pips
            if display.legalDestinations.contains(bIdx) {
                if display.board.squares[bIdx] != nil {
                    // Capture: ring around occupied square
                    Circle()
                        .strokeBorder(Color.black.opacity(0.25), lineWidth: sqSz * 0.08)
                        .padding(2)
                } else {
                    // Empty: small dot
                    Circle()
                        .fill(Color.black.opacity(0.20))
                        .frame(width: sqSz * 0.28, height: sqSz * 0.28)
                }
            }

            // Manual robot selection highlight (paused mode)
            if gameStore.manualRobotSelectIdx == bIdx {
                Color.orange.opacity(0.40)
            }

            // Piece (hidden while being dragged)
            if draggingFromVisualIdx != visualIdx {
                if let piece = display.board.squares[bIdx] {
                    pieceImage(piece)
                }
            }
        }
    }

    // MARK: - Drag gesture

    private func dragGesture(sqSz: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if draggingFromVisualIdx == nil {
                    guard let vIdx = visualIndex(at: value.startLocation, sqSz: sqSz) else { return }
                    let bIdx = boardIndex(vIdx)
                    let started = gameStore.handleDragStart(at: bIdx)
                    guard started else { return }
                    draggingFromVisualIdx = vIdx
                }
                guard let fromVisual = draggingFromVisualIdx else { return }
                let center = squareCenter(visualIdx: fromVisual, sqSz: sqSz)
                dragOffset = CGSize(
                    width:  value.location.x - center.x,
                    height: value.location.y - center.y
                )
            }
            .onEnded { value in
                defer {
                    draggingFromVisualIdx = nil
                    dragOffset = .zero
                }
                guard draggingFromVisualIdx != nil else { return }

                guard let toVisual = visualIndex(at: value.location, sqSz: sqSz) else {
                    return
                }
                let to = boardIndex(toVisual)
                isDropping = true
                gameStore.handleDrop(at: to)

                // Fallback reset if the move was illegal (FEN unchanged after 0.1s).
                let fenBefore = gameStore.displayFEN
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if gameStore.displayFEN == fenBefore { isDropping = false }
                }
            }
    }

    // MARK: - Helpers

    private func boardIndex(_ visualIdx: Int) -> Int {
        isFlipped ? (63 - visualIdx) : visualIdx
    }

    private func visualIndex(at point: CGPoint, sqSz: CGFloat) -> Int? {
        guard sqSz > 0 else { return nil }
        let col = Int(point.x / sqSz)
        let row = Int(point.y / sqSz)
        guard (0..<8).contains(col), (0..<8).contains(row) else { return nil }
        return row * 8 + col
    }

    private func squareCenter(visualIdx: Int, sqSz: CGFloat) -> CGPoint {
        CGPoint(
            x: CGFloat(visualIdx % 8) * sqSz + sqSz / 2,
            y: CGFloat(visualIdx / 8) * sqSz + sqSz / 2
        )
    }

    private func squareColor(_ idx: Int) -> Color {
        // Dark square when rank + file is even (matches standard chess coloring).
        let rank = idx.rank
        let file = idx.file
        return (rank + file) % 2 == 0 ? boardTheme.dark : boardTheme.light
    }

    @ViewBuilder
    private func pieceImage(_ piece: Piece) -> some View {
        PieceSetImageView(piece: piece, pieceSet: pieceSet)
    }
}

// MARK: - PieceSetImageView bridge
//
// PieceSetImageView previously took a Chess.Piece from the library.
// It now takes our own Piece type. Update PieceSetImageView to accept
// Dacelo.Piece (side: Side, type: PieceType) instead of Chess.Piece.

extension Piece {
    /// Maps our Piece to the image name expected by PieceSetImageView.
    var imageName: String {
        let sidePrefix = side == .white ? "w" : "b"
        return "\(sidePrefix)\(type.rawValue)"
    }
}
