// PositionCharacteristics.swift
// Dacelo
// Models/

import Foundation

struct PositionCharacteristics: Codable {
    let sharpness: String        // "Sharp" | "Tactical" | "Balanced" | "Quiet"
    let difficulty: String       // "Beginner" | "Intermediate" | "Advanced" | "Expert"
    let margin_for_error: String // "Narrow" | "Moderate" | "Forgiving"
    let line_type: String        // "Forcing" | "Committal" | "Flexible" | "Quiet"
    let explanation: String
}
