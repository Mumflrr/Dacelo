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
    private let lock  = NSLock()
    private init() {}

    func get(_ key: String) -> Image? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }
    func set(_ key: String, _ image: Image) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = image
    }
}

// MARK: - Bundle image loader
//
// macOS  → loads .svg  (NSImage handles SVG natively)
// iOS    → loads .png  (converted from SVG at build time by the Run Script phase)
//
// Run Script (add BEFORE the Copy Bundle Resources phase, iOS target):
//
//   PIECES_SRC="${SRCROOT}/Dacelo/Pieces"
//   PIECES_DST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Pieces"
//   find "$PIECES_SRC" -name "*.svg" | while read svg; do
//     folder=$(basename "$(dirname "$svg")")
//     name=$(basename "$svg" .svg)
//     dst_dir="$PIECES_DST/$folder"
//     mkdir -p "$dst_dir"
//     sips -s format png "$svg" --out "$dst_dir/$name.png" 2>/dev/null
//   done

func bundlePieceImage(named name: String, inFolder folder: String) -> Image? {
    let key = "\(folder)/\(name)"
    if let hit = PieceImageCache.shared.get(key) { return hit }

    #if os(macOS)
    guard
        let url = Bundle.main.url(forResource: name,
                                  withExtension: "svg",
                                  subdirectory: "Pieces/\(folder)"),
        let ns  = NSImage(contentsOf: url)
    else { return nil }
    let image = Image(nsImage: ns)

    #else
    // sips converts SVG → PNG preserving the filename stem.
    guard
        let url = Bundle.main.url(forResource: name,
                                  withExtension: "png",
                                  subdirectory: "Pieces/\(folder)"),
        let ui  = UIImage(contentsOfFile: url.path)
    else { return nil }
    let image = Image(uiImage: ui)
    #endif

    PieceImageCache.shared.set(key, image)
    return image
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

struct PieceSetImageView: View {
    let piece: Chess.Piece
    let pieceSet: PieceSet

    var body: some View {
        let name = pieceSet.fileName(for: piece)
        if let img = bundlePieceImage(named: name, inFolder: pieceSet.rawValue) {
            img.resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Text(unicodeFallback).font(.system(size: 36))
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
        return unicodeGlyph(type: t, side: piece.side == .white ? "white" : "black")
    }
}

// MARK: - PieceSetPieceView

struct PieceSetPieceView: View {
    let pieceType: String  // "p","n","b","r","q","k"
    let side: String       // "white" | "black"
    let pieceSet: PieceSet

    var body: some View {
        let name = pieceSet.pieceFileName(type: pieceType, side: side)
        if let img = bundlePieceImage(named: name, inFolder: pieceSet.rawValue) {
            img.resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Text(unicodeGlyph(type: pieceType, side: side)).font(.system(size: 26))
        }
    }
}

// MARK: - PieceSetKingView

struct PieceSetKingView: View {
    let side: String
    let pieceSet: PieceSet

    var body: some View {
        PieceSetPieceView(pieceType: "k", side: side, pieceSet: pieceSet)
    }
}

// MARK: - PieceSetSwatch
//
// • Swatches are right-aligned (frame maxWidth: .infinity + trailing HStack).
// • The tile has 2 px top padding so the selected border isn't clipped by the
//   parent's overlay on both macOS and iOS.
// • scaleEffect on the whole VStack matches BoardThemeSwatch exactly.

struct PieceSetSwatch: View {
    let pieceSet: PieceSet
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            // 2 px top inset so the border renders fully without clipping.
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                    .frame(width: 44, height: 44)
                PieceSetKingView(side: "white", pieceSet: pieceSet)
                    .frame(width: 32, height: 32)
            }
            .padding(.top, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.white : Color.white.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
                    // Offset the border rect down to match the 2 px top padding.
                    .padding(.top, 2)
            )
            .shadow(color: isSelected ? .white.opacity(0.3) : .clear, radius: 4)

            Text(pieceSet.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                .lineLimit(1)
        }
        // Fixed width so scale never shifts neighbours.
        .frame(width: 52)
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
        .help(pieceSet.displayName)
    }
}
