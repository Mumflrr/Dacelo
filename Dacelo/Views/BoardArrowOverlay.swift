// BoardArrowOverlay.swift
// Dacelo
//
// Draws best-move arrows on top of BoardView.
// Supports multiple arrows: rank 1 = yellow, rank 2 = cyan, rank 3 = orange.
//
// Coordinate mapping (matches BoardView's LazyVGrid, index 0 = a8 top-left):
//   col = file index 0–7 (a=0 … h=7), left to right
//   row = 8 - rank (rank 8 = row 0 at top, rank 1 = row 7 at bottom)

import SwiftUI

struct BoardArrowOverlay: View {
    /// Ordered list of arrows. Index 0 = best, 1 = second best, etc.
    let arrows: [(from: String, to: String)]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            Canvas { ctx, _ in
                for (rank, arrow) in arrows.enumerated() {
                    guard let fromPt = squareCenter(arrow.from, boardSize: size),
                          let toPt   = squareCenter(arrow.to,   boardSize: size) else { continue }
                    let color = arrowColor(rank: rank)
                    drawArrow(ctx: ctx, from: fromPt, to: toPt,
                              boardSize: size, color: color, rank: rank)
                }
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Colors per rank

    private func arrowColor(rank: Int) -> Color {
        switch rank {
        case 0: return Color.green
        case 1: return Color.cyan
        default: return Color.red
        }
    }

    // MARK: - Coordinate math

    private func squareCenter(_ square: String, boardSize: CGFloat) -> CGPoint? {
        guard square.count >= 2 else { return nil }
        let chars    = Array(square.lowercased())
        let fileChar = chars[0]
        let rankChar = chars[1]
        guard let fileIdx = "abcdefgh".firstIndex(of: fileChar),
              let rank    = rankChar.wholeNumberValue,
              rank >= 1, rank <= 8 else { return nil }

        let col = CGFloat("abcdefgh".distance(from: "abcdefgh".startIndex, to: fileIdx))
        let row = CGFloat(8 - rank)
        let sq  = boardSize / 8
        return CGPoint(x: col * sq + sq / 2, y: row * sq + sq / 2)
    }

    // MARK: - Arrow drawing
    // Draws a thick outline first (for contrast on any board color), then the fill.

    private func drawArrow(
        ctx: GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        boardSize: CGFloat,
        color: Color,
        rank: Int
    ) {
        let sq        = boardSize / 8
        // Secondary arrows are slightly thinner so rank 1 reads clearest
        let lineW     = sq * 0.13
        let headLen   = sq * 0.36
        let headWidth = sq * 0.26
        let opacity   = 0.85

        let dx  = to.x - from.x
        let dy  = to.y - from.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return }
        let ux = dx / len, uy = dy / len

        let shaftEnd = CGPoint(x: to.x - ux * headLen * 0.55,
                               y: to.y - uy * headLen * 0.55)

        var shaft = Path()
        shaft.move(to: from)
        shaft.addLine(to: shaftEnd)

        let px = -uy, py = ux
        let tip   = CGPoint(x: to.x + ux * sq * 0.02, y: to.y + uy * sq * 0.02)
        let base  = CGPoint(x: tip.x - ux * headLen,  y: tip.y - uy * headLen)
        let left  = CGPoint(x: base.x + px * headWidth, y: base.y + py * headWidth)
        let right = CGPoint(x: base.x - px * headWidth, y: base.y - py * headWidth)

        var head = Path()
        head.move(to: tip)
        head.addLine(to: left)
        head.addLine(to: right)
        head.closeSubpath()

        let outlineW = lineW + 2.5
        // Outline pass
        ctx.stroke(shaft,
                   with: .color(.black.opacity(0.3)),
                   style: StrokeStyle(lineWidth: outlineW, lineCap: .round))
        ctx.fill(head, with: .color(.black.opacity(0.3)))

        // Color pass
        ctx.stroke(shaft,
                   with: .color(color.opacity(opacity)),
                   style: StrokeStyle(lineWidth: lineW, lineCap: .round))
        ctx.fill(head, with: .color(color.opacity(opacity)))
    }
}
