// PositionCharacteristics.swift
// Dacelo
// Models/

import Foundation

struct PositionCharacteristics: Codable {

    // ── Primary labels (new, better names) ───────────────────────────────────

    /// How equal the top engine moves are: "Equal" | "Unbalanced" | "Complex" | "Critical"
    /// Equal = multiple moves are nearly as good (low pressure).
    /// Critical = one move only — miss it and lose ground fast.
    let position_type:      String

    /// How much better the best move is vs the alternatives:
    /// "Low" | "Moderate" | "High" | "Very High"
    let precision_required: String

    /// How stable the engine eval was across search depths:
    /// "Stable" | "Fluctuating" | "Volatile"
    /// Volatile means this is a hard-to-evaluate position — treat the score with caution.
    let eval_stability:     String

    /// What the best continuation looks like:
    /// "Forcing" | "Tactical" | "Committal" | "Flexible" | "Quiet"
    let line_type:          String

    /// Human-readable summary combining all of the above.
    let explanation:        String

    /// One-line note about eval stability for display.
    let stability_note:     String

    // ── Legacy aliases (kept for backwards compat with server JSON keys) ──────
    /// Deprecated: use position_type
    let sharpness:          String
    /// Deprecated: use precision_required
    let difficulty:         String
    /// Deprecated: use precision_required
    let margin_for_error:   String
    /// Deprecated: use eval_stability
    let confidence:         String

    // ── Convenience init (new field names only) ──────────────────────────────
    // Legacy aliases are derived automatically so call sites don't need to
    // supply them — only the server JSON decoder needs all fields populated,
    // and the server always sends both old and new keys for compat.
    init(
        position_type:      String,
        precision_required: String,
        eval_stability:     String,
        line_type:          String,
        explanation:        String,
        stability_note:     String = ""
    ) {
        self.position_type      = position_type
        self.precision_required = precision_required
        self.eval_stability     = eval_stability
        self.line_type          = line_type
        self.explanation        = explanation
        self.stability_note     = stability_note
        // Populate legacy aliases from new values
        self.sharpness          = position_type
        self.difficulty         = precision_required
        self.margin_for_error   = precision_required
        self.confidence         = eval_stability
    }
}
