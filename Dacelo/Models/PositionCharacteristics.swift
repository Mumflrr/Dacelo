// PositionCharacteristics.swift
// Dacelo
// Models/

import Foundation

struct PositionCharacteristics: Codable {
    /// Score spread across MultiPV lines: "Quiet" | "Balanced" | "Tactical" | "Sharp"
    let sharpness:        String
    /// CP gap between best and second-best move: "Beginner" | "Intermediate" | "Advanced" | "Expert"
    let difficulty:       String
    /// English label for the same gap: "Forgiving" | "Moderate" | "Narrow"
    let margin_for_error: String
    /// Derived from PV capture/check analysis: "Forcing" | "Tactical" | "Committal" | "Flexible" | "Quiet"
    let line_type:        String
    /// Score stability across search depths: "Confident" | "Uncertain" | "Volatile"
    let confidence:       String
    let explanation:      String
}
