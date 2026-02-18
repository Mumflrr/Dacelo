// MoveCritique.swift
// Dacelo
//
// Model for tracking and displaying move-by-move analysis

import Foundation
import Chess

// MARK: - Move Critique Model

struct MoveCritique: Identifiable, Codable {
    let id: UUID
    let moveNumber: Int
    let side: String              // "white" or "black"
    let move: String              // UCI notation "e2e4"
    let moveNotation: String      // Algebraic "e4"
    let scoreBefore: Int?         // centipawns before move
    let scoreAfter: Int?          // centipawns after move
    let classification: MoveQuality
    let comment: String
    let alternatives: [AlternativeMove]
    let characteristics: PositionCharacteristics?
    
    init(id: UUID = UUID(),
         moveNumber: Int,
         side: String,
         move: String,
         moveNotation: String,
         scoreBefore: Int?,
         scoreAfter: Int?,
         classification: MoveQuality,
         comment: String,
         alternatives: [AlternativeMove],
         characteristics: PositionCharacteristics?) {
        self.id = id
        self.moveNumber = moveNumber
        self.side = side
        self.move = move
        self.moveNotation = moveNotation
        self.scoreBefore = scoreBefore
        self.scoreAfter = scoreAfter
        self.classification = classification
        self.comment = comment
        self.alternatives = alternatives
        self.characteristics = characteristics
    }
}

// MARK: - Move Quality

enum MoveQuality: String, Codable {
    case excellent   = "Excellent"
    case good        = "Good"
    case inaccuracy  = "Inaccuracy"
    case mistake     = "Mistake"
    case blunder     = "Blunder"
    case book        = "Book Move"
    case unknown     = "Unknown"
}

// MARK: - Alternative Move

struct AlternativeMove: Codable, Identifiable {
    var id: Int { rank }
    let rank: Int
    let move: String
    let scoreCP: Int?
    let scoreMate: Int?
}

// MARK: - Position Characteristics

struct PositionCharacteristics: Codable {
    let sharpness: String         // "Sharp" | "Tactical" | "Balanced" | "Quiet"
    let difficulty: String        // "Beginner" | "Intermediate" | "Advanced" | "Expert"
    let margin_for_error: String  // "Narrow" | "Moderate" | "Forgiving"
    let line_type: String         // "Forcing" | "Committal" | "Flexible" | "Quiet"
    let explanation: String
}
