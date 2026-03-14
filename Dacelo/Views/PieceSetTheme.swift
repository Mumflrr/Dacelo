// PieceSetTheme.swift
// Dacelo

import SwiftUI
import Chess

// MARK: - PieceSet

enum PieceSet: String, CaseIterable, Identifiable {
    case cburnett = "cburnett"
    case riohacha = "riohacha"
    case anarchy  = "anarchy"
    case horsey   = "horsey"
    case staunty  = "staunty"
    case caliente = "caliente"

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    func fileName(for piece: Chess.Piece) -> String {
        let t: String
        switch piece.pieceType {
        case .pawn:   t = "p"
        case .knight: t = "n"
        case .bishop: t = "b"
        case .rook:   t = "r"
        case .queen:  t = "q"
        case .king:   t = "k"
        default:      t = "p"
        }
        return t + colorCode(piece.side)
    }

    func kingFileName(side: String) -> String {
        "k" + (side == "white" ? "w" : "b")
    }

    func pieceFileName(type: String, side: String) -> String {
        type + (side == "white" ? "w" : "b")
    }

    private func colorCode(_ side: Chess.Side) -> String {
        side == .white ? "w" : "b"
    }
}

// MARK: - Image cache

private final class PieceImageCache {
    static let shared = PieceImageCache()
    private var cache: [String: Image] = [:]
    private init() {}

    func image(forKey key: String, loader: () -> Image?) -> Image? {
        if let hit = cache[key] { return hit }
        if let img = loader() { cache[key] = img; return img }
        return nil
    }
}

// MARK: - Platform SVG loader

func bundleSVGImage(named name: String, inFolder folder: String) -> Image? {
    let key = "\(folder)/\(name)"
    return PieceImageCache.shared.image(forKey: key) {
        #if os(macOS)
        guard
            let url = Bundle.main.url(forResource: name,
                                      withExtension: "svg",
                                      subdirectory: "Pieces/\(folder)"),
            let ns  = NSImage(contentsOf: url)
        else { return nil }
        return Image(nsImage: ns)
        #else
        if let ui = UIImage(named: "\(folder)_\(name)") {
            return Image(uiImage: ui)
        }
        return nil
        #endif
    }
}

// MARK: - Unicode fallback helpers

private let unicodeWhite: [String: String] = [
    "k": "♔", "q": "♕", "r": "♖", "b": "♗", "n": "♘", "p": "♙"
]
private let unicodeBlack: [String: String] = [
    "k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"
]

private func unicodeGlyph(type: String, side: String) -> String {
    (side == "white" ? unicodeWhite : unicodeBlack)[type] ?? "♙"
}

// MARK: - PieceSetImageView
// Renders a Chess.Piece using the chosen SVG set.
// Falls back to a Unicode glyph (no library dependency) when the SVG is missing.

struct PieceSetImageView: View {
    let piece: Chess.Piece
    let pieceSet: PieceSet

    var body: some View {
        let name = pieceSet.fileName(for: piece)
        if let img = bundleSVGImage(named: name, inFolder: pieceSet.rawValue) {
            img.resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Text(unicodeFallback)
                .font(.system(size: 36))
        }
    }

    private var unicodeFallback: String {
        let t: String
        switch piece.pieceType {
        case .knight: t = "n"
        case .bishop: t = "b"
        case .rook:   t = "r"
        case .queen:  t = "q"
        case .king:   t = "k"
        default:      t = "p"
        }
        let side = piece.side == .white ? "white" : "black"
        return unicodeGlyph(type: t, side: side)
    }
}

// MARK: - PieceSetPieceView
// Renders any piece by type string ("p","n","b","r","q","k") and side string.
// Used in move history cards which store piece type separately.

struct PieceSetPieceView: View {
    let pieceType: String  // "p","n","b","r","q","k"
    let side: String       // "white" | "black"
    let pieceSet: PieceSet

    var body: some View {
        let name = pieceSet.pieceFileName(type: pieceType, side: side)
        if let img = bundleSVGImage(named: name, inFolder: pieceSet.rawValue) {
            img.resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Text(unicodeGlyph(type: pieceType, side: side))
                .font(.system(size: 26))
        }
    }
}

// MARK: - PieceSetKingView
// Renders just a king for a given side string. Used in move-history cards.

struct PieceSetKingView: View {
    let side: String
    let pieceSet: PieceSet

    var body: some View {
        PieceSetPieceView(pieceType: "k", side: side, pieceSet: pieceSet)
    }
}

// MARK: - PieceSetSwatch (for settings UI)
// Sized to sit inline next to the "Pieces" label, matching BoardThemeSwatch proportions.

struct PieceSetSwatch: View {
    let pieceSet: PieceSet
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                    .frame(width: 44, height: 44)
                PieceSetKingView(side: "white", pieceSet: pieceSet)
                    .frame(width: 32, height: 32)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.white : Color.white.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(color: isSelected ? .white.opacity(0.25) : .clear, radius: 4)
            Text(pieceSet.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(isSelected ? 0 : 2)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
        .help(pieceSet.displayName)
    }
}
