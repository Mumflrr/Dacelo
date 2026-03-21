// BoardView.swift
// Dacelo

import SwiftUI
import Chess

// MARK: - Board

struct BoardLayout: View {
    @EnvironmentObject var gameStore: GameStore
    let boardTheme: BoardTheme
    let pieceSet: PieceSet
    let isFlipped: Bool

    let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)

    @State private var draggingFromVisualIdx: Int? = nil
    @State private var dragOffset: CGSize          = .zero
    @State private var squareSize: CGFloat         = 0
    @State private var isDropping: Bool            = false

    // Always current — reads directly from the @Published property on gameStore.
    private var activeStore: ChessStore { gameStore.displayChessStore }

    init(boardTheme: BoardTheme, pieceSet: PieceSet, isFlipped: Bool) {
        self.boardTheme = boardTheme
        self.pieceSet   = pieceSet
        self.isFlipped  = isFlipped
    }

    var body: some View {
        // ── Re-render dependency ─────────────────────────────────────────────
        //
        // Reading displayBoardFEN here registers a SwiftUI dependency on it.
        // Both the live-game sink and the scratch-game sink in GameStore write
        // to this @Published String (always on main). This body re-evaluates
        // after every accepted move in either mode, which is what clears the
        // dragging state and re-draws piece positions correctly.
        //
        // The old code watched activeStore.game.board.FEN — a computed property
        // on an unobserved reference type — which never triggered a re-render
        // when a scratch move was accepted.
        let _ = gameStore.displayBoardFEN

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
                                .environmentObject(activeStore)

                            if !isDropping {
                                SquareMoveHighlight(bIdx)
                                    .environmentObject(activeStore)
                                SquareSelected(bIdx)
                                    .environmentObject(activeStore)
                                SquareTargeted(bIdx)
                                    .environmentObject(activeStore)
                            }

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
                   let piece = activeStore.game.board.squares[Chess.Position(boardIdx(fromVisual))].piece {
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
                        guard !gameStore.isReplayingMoves else { return }
                        if draggingFromVisualIdx == nil {
                            if gameStore.positionOverrideFEN != nil && !gameStore.isExploringScratch {
                                beginScratchFromHistory()
                            }

                            guard
                                let vIdx  = squareVisualIdx(at: value.startLocation, sqSz: sqSz),
                                let piece = activeStore.game.board.squares[Chess.Position(boardIdx(vIdx))].piece,
                                canDragPiece(piece, at: boardIdx(vIdx))
                            else { return }
                            draggingFromVisualIdx = vIdx
                            activeStore.gameAction(.userDragged(position: boardIdx(vIdx)))
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

                        if let toVisual = squareVisualIdx(at: value.location, sqSz: sqSz) {
                            let to = boardIdx(toVisual)
                            if gameStore.isPaused && gameStore.isRobotsTurn() {
                                draggingFromVisualIdx = nil
                                dragOffset = .zero
                                gameStore.manualSelectIdx = nil
                                robotController?.submitManualMove(from: boardIdx(fromVisual), to: to)
                            } else {
                                isDropping = true
                                activeStore.gameAction(.userDropped(position: to))

                                // Fallback reset if the drop was illegal (FEN unchanged).
                                let fenBefore = activeStore.game.board.FEN
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if activeStore.game.board.FEN == fenBefore {
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
            // ── Drag state cleanup ────────────────────────────────────
            //
            // Watches gameStore.displayBoardFEN (a @Published String updated by
            // both the live and scratch sinks on the main thread) rather than
            // activeStore.game.board.FEN (a computed property on an unobserved
            // reference that never triggered this onChange for scratch moves).
            .onChange(of: gameStore.displayBoardFEN) { _, _ in
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
        print("TAP bIdx=\(bIdx) isExploring=\(gameStore.isExploringScratch) overrideFEN=\(gameStore.positionOverrideFEN != nil) isPaused=\(gameStore.isPaused)")
        guard !gameStore.isReplayingMoves else { return }

        if gameStore.isPaused && gameStore.isRobotsTurn() {
            print("TAP → manual move path, returning early")
            gameStore.handleManualTap(boardIdx: bIdx)
            return
        }

        if gameStore.positionOverrideFEN != nil && !gameStore.isExploringScratch {
            beginScratchFromHistory()
        }

        let storeFEN   = activeStore.game.board.FEN
        let userPaused = activeStore.game.userPaused
        let side       = activeStore.game.board.playingSide
        print("[scratch] status=\(activeStore.game.computeGameStatus()) paused=\(activeStore.game.userPaused)")
        print("FIRING ACTION on store FEN=\(storeFEN) userPaused=\(userPaused) playingSide=\(side)")
        activeStore.gameAction(.userTappedSquare(position: bIdx))
        print("AFTER ACTION store FEN=\(activeStore.game.board.FEN)")
        print("[turn] playingSide=\(activeStore.game.board.playingSide) white=\(type(of: activeStore.game.white)) black=\(type(of: activeStore.game.black))")
    }

    /// Build the move list from moveCritiques up to the selected index and
    /// hand it to GameStore to replay into a fresh scratch ChessStore.
    private func beginScratchFromHistory() {
        guard let fen = gameStore.positionOverrideFEN else { return }
        print("BEGIN SCRATCH from FEN: \(fen)")
        gameStore.beginScratchExploration(targetFEN: fen, lastMove: gameStore.positionOverrideLastMove)
    }

    // MARK: - Drag permission

    private func canDragPiece(_ piece: Chess.Piece, at bIdx: Int) -> Bool {
        if gameStore.isPaused && gameStore.isRobotsTurn() {
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

    // MARK: - Robot controller

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
        if let piece = activeStore.game.board.squares[Chess.Position(bIdx)].piece {
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
