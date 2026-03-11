// MoveCritique.swift
// Dacelo
// Models/

import Foundation
import SwiftUI

// MARK: - Move Quality

enum MoveQuality: String, Codable {
    case excellent   = "Excellent"
    case good        = "Good"
    case inaccuracy  = "Inaccuracy"
    case mistake     = "Mistake"
    case blunder     = "Blunder"
    case book        = "Book Move"
    case unknown     = "Unknown"

    var color: Color {
        switch self {
        case .excellent:  return .green
        case .good:       return .blue
        case .inaccuracy: return .yellow
        case .mistake:    return .orange
        case .blunder:    return .red
        case .book:       return .purple
        case .unknown:    return .gray
        }
    }

    var icon: String {
        switch self {
        case .excellent:  return "star.fill"
        case .good:       return "checkmark.circle.fill"
        case .inaccuracy: return "exclamationmark.triangle.fill"
        case .mistake:    return "xmark.circle.fill"
        case .blunder:    return "flame.fill"
        case .book:       return "book.fill"
        case .unknown:    return "questionmark.circle"
        }
    }
}

// MARK: - Alternative Move

struct AlternativeMove: Codable, Identifiable {
    var id: Int { rank }
    let rank: Int
    let move: String
    let scoreCP: Int?
    let scoreMate: Int?
}

// MARK: - Move Critique

struct MoveCritique: Identifiable, Codable {
    let id: UUID
    let moveNumber: Int
    let side: String           // "white" | "black"
    let move: String           // UCI "e2e4"
    let moveNotation: String   // label "1." or "1..."
    let scoreBefore: Int?      // white-positive centipawns before move
    let scoreAfter: Int?       // white-positive centipawns after move
    let classification: MoveQuality
    let comment: String
    let alternatives: [AlternativeMove]
    let characteristics: PositionCharacteristics?

    init(
        id: UUID = UUID(),
        moveNumber: Int,
        side: String,
        move: String,
        moveNotation: String,
        scoreBefore: Int?,
        scoreAfter: Int?,
        classification: MoveQuality,
        comment: String,
        alternatives: [AlternativeMove],
        characteristics: PositionCharacteristics?
    ) {
        self.id             = id
        self.moveNumber     = moveNumber
        self.side           = side
        self.move           = move
        self.moveNotation   = moveNotation
        self.scoreBefore    = scoreBefore
        self.scoreAfter     = scoreAfter
        self.classification = classification
        self.comment        = comment
        self.alternatives   = alternatives
        self.characteristics = characteristics
    }
}
