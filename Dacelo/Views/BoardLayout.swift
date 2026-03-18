// BoardView.swift
// Dacelo

import SwiftUI
import Chess

// MARK: - Board

struct BoardLayout: View {
    @EnvironmentObject var store:     ChessStore
    @EnvironmentObject var gameStore: GameStore
    let boardTheme: BoardTheme
    let pieceSet: PieceSet
    /// True when the board should be shown from Black's perspective (h1 top-left).
    let isFlipped: Bool

    let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)

    // All stored drag indices are VISUAL indices (position in the grid 0-63).
    // Convert to boardIdx() before any store action.
    @State private var draggingFromVisualIdx: Int? = nil
    @State private var dragOffset: CGSize          = .zero
    @State private var squareSize: CGFloat         = 0
    @State private var isDropping: Bool            = false
    
    /// Always returns the store that should receive game actions right now.
    /// Reads directly from gameStore (always current) rather than the injected
    /// `store` EnvironmentObject which can be one render cycle behind.
    private var activeStore: ChessStore {
        gameStore.displayChessStore
    }
    
    init(boardTheme: BoardTheme, pieceSet: PieceSet, isFlipped: Bool) {
            self.boardTheme = boardTheme
            self.pieceSet = pieceSet
            self.isFlipped = isFlipped
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let sqSz = side / 8

            ZStack {
                // ── Grid ─────────────────────────────────────────────
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(0..<64) { visualIdx in
                        let bIdx = boardIdx(visualIdx)
                        ZStack {
                            SquareBackground(idx: bIdx, theme: boardTheme)

                            if !isDropping {
                                SquareMoveHighlight(bIdx)
                                SquareSelected(bIdx)
                                SquareTargeted(bIdx)
                            }

                            // Manual selection highlight (user playing for Leela).
                            if gameStore.manualSelectIdx == bIdx {
                                Rectangle()
                                    .fill(Color.yellow.opacity(0.45))
                            }

                            if draggingFromVisualIdx != visualIdx {
                                squarePiece(for: bIdx)
                            }
                        }
                        .frame(width: sqSz, height: sqSz)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleTap(boardIdx: bIdx)
                        }
                    }
                }
                .frame(width: side, height: side)

                // ── Floating piece during drag ────────────────────────
                if let fromVisual = draggingFromVisualIdx,
                   let piece = store.game.board.squares[Chess.Position(boardIdx(fromVisual))].piece {
                    PieceSetImageView(piece: piece, pieceSet: pieceSet)
                        .frame(width: sqSz * 1.15, height: sqSz * 1.15)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .offset(dragOffset)
                        .position(squareCenter(visualIdx: fromVisual, sqSz: sqSz))
                        .allowsHitTesting(false)
                        .zIndex(10)
                        .animation(.interactiveSpring(response: 0.15), value: dragOffset)
                }
            }
            .frame(width: side, height: side)
            // ── Drag gesture ─────────────────────────────────────────
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { value in
                        if draggingFromVisualIdx == nil {
                            // Bootstrap scratch at drag START so both userDragged and
                            // userDropped go to the same store in the same gesture.
                            if gameStore.positionOverrideFEN != nil && !gameStore.isExploringScratch {
                                guard let fen = gameStore.positionOverrideFEN else { return }
                                gameStore.beginScratchExploration(from: fen)
                            }

                            let target = activeStore
                            guard
                                let vIdx  = squareVisualIdx(at: value.startLocation, sqSz: sqSz),
                                let piece = target.game.board.squares[Chess.Position(boardIdx(vIdx))].piece,
                                canDragPiece(piece, at: boardIdx(vIdx))
                            else { return }
                            draggingFromVisualIdx = vIdx
                            target.gameAction(.userDragged(position: boardIdx(vIdx)))
                        }
                        guard let fromVisual = draggingFromVisualIdx else { return }
                        let center = squareCenter(visualIdx: fromVisual, sqSz: sqSz)
                        dragOffset = CGSize(
                            width:  value.location.x - center.x,
                            height: value.location.y - center.y
                        )
                    }
                    .onEnded { value in
                        guard let fromVisual = draggingFromVisualIdx else { return }
                        let target = activeStore

                        if let toVisual = squareVisualIdx(at: value.location, sqSz: sqSz) {
                            let to = boardIdx(toVisual)
                            if gameStore.isPaused && gameStore.isRobotsTurn() {
                                draggingFromVisualIdx = nil
                                dragOffset = .zero
                                gameStore.manualSelectIdx = nil
                                robotController?.submitManualMove(from: boardIdx(fromVisual), to: to)
                            } else {
                                isDropping = true
                                target.gameAction(.userDropped(position: to))

                                let fenBefore = target.game.board.FEN
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    if target.game.board.FEN == fenBefore {
                                        draggingFromVisualIdx = nil
                                        dragOffset = .zero
                                        isDropping = false
                                    }
                                }
                            }
                        } else {
                            draggingFromVisualIdx = nil
                            dragOffset = .zero
                        }
                    }
            )
            .onChange(of: gameStore.scratchChessStore?.game.board.FEN) { _, _ in
                withAnimation(.easeOut(duration: 0.08)) {
                    draggingFromVisualIdx = nil
                    dragOffset            = .zero
                }
                isDropping = false
            }
            .onAppear   { squareSize = sqSz }
            .onChange(of: sqSz) { _, new in squareSize = new }
        }
    }

    // MARK: - Tap handling
    private func handleTap(boardIdx bIdx: Int) {
        if gameStore.isPaused && gameStore.isRobotsTurn() {
            gameStore.handleManualTap(boardIdx: bIdx)
            return
        }

        // If reviewing history (with or without scratch already active),
        // bootstrap scratch if needed then always route to it directly.
        if gameStore.positionOverrideFEN != nil {
            if !gameStore.isExploringScratch {
                guard let fen = gameStore.positionOverrideFEN else { return }
                gameStore.beginScratchExploration(from: fen)
            }
            gameStore.scratchChessStore?.gameAction(.userTappedSquare(position: bIdx))
            return
        }

        store.gameAction(.userTappedSquare(position: bIdx))
    }

    // MARK: - Drag permission

    /// Allow dragging a piece if it matches the active side, OR if paused and
    /// it belongs to Leela (so the user can drag-move on her behalf).
    private func canDragPiece(_ piece: Chess.Piece, at bIdx: Int) -> Bool {
        if gameStore.isPaused && gameStore.isRobotsTurn() {
            // Allow dragging the robot's pieces when taking Leela's turn.
            let leelaIsBlack = gameStore.playerColor == .white
            return leelaIsBlack ? piece.side == .black : piece.side == .white
        }
        return pieceMatchesActiveSide(piece)
    }

    // MARK: - Flip

    private func boardIdx(_ visualIdx: Int) -> Int {
        isFlipped ? (63 - visualIdx) : visualIdx
    }

    // MARK: - Active-side guard

    private func pieceMatchesActiveSide(_ piece: Chess.Piece) -> Bool {
        let parts = activeStore.game.board.FEN.split(separator: " ")
        guard parts.count > 1 else { return true }
        switch String(parts[1]) {
        case "w": return piece.side == .white
        case "b": return piece.side == .black
        default:  return true
        }
    }

    // MARK: - Robot controller convenience

    private var robotController: RobotController? {
        gameStore.gameMode == .humanVsEngine ? gameStore.robotController : nil
    }

    // MARK: - Coordinate helpers

    private func squareVisualIdx(at point: CGPoint, sqSz: CGFloat) -> Int? {
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

    @ViewBuilder
    private func squarePiece(for bIdx: Int) -> some View {
        if let piece = store.game.board.squares[Chess.Position(bIdx)].piece {
            PieceSetImageView(piece: piece, pieceSet: pieceSet)
        }
    }
}

// MARK: - Custom square background

struct SquareBackground: View {
    @EnvironmentObject var store: ChessStore
    let idx: Int
    let theme: BoardTheme

    var body: some View {
        Rectangle()
            .fill(squareColor)
            .aspectRatio(1, contentMode: .fill)
    }

    private var squareColor: Color {
        let pos    = Chess.Position(idx)
        let isDark = (pos.rank + pos.fileNumber) % 2 == 0
        return isDark ? theme.dark : theme.light
    }
}
