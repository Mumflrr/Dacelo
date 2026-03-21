// PieceSetTheme.swift
// Dacelo

import SwiftUI

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

    func fileName(for piece: Piece) -> String {
        piece.type.rawValue + colorCode(piece.side)
    }

    func kingFileName(side: String) -> String {
        "k" + (side == "white" ? "w" : "b")
    }

    func pieceFileName(type: String, side: String) -> String {
        type + (side == "white" ? "w" : "b")
    }

    private func colorCode(_ side: Side) -> String {
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
    let piece:    Piece
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
        unicodeGlyph(type: piece.type.rawValue,
                     side: piece.side == .white ? "white" : "black")
    }
}

// MARK: - PieceSetPieceView

struct PieceSetPieceView: View {
    let pieceType: String   // "p","n","b","r","q","k"
    let side:      String   // "white" | "black"
    let pieceSet:  PieceSet

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
    let side:     String
    let pieceSet: PieceSet

    var body: some View {
        PieceSetPieceView(pieceType: "k", side: side, pieceSet: pieceSet)
    }
}

// MARK: - PieceSetSwatch

struct PieceSetSwatch: View {
    let pieceSet:  PieceSet
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
            .padding(.top, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.white : Color.white.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1
                    )
                    .padding(.top, 2)
            )
            .shadow(color: isSelected ? .white.opacity(0.3) : .clear, radius: 4)

            Text(pieceSet.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(width: 52)
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
        .help(pieceSet.displayName)
    }
}
