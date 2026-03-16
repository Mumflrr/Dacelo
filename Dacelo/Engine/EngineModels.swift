// EngineModels.swift
// Dacelo
//
// All response types decoded from the chess WebSocket server.

import Foundation

// MARK: - Errors

enum EngineError: LocalizedError {
    case notConnected
    case serverError(String)
    case timeout
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:         return "Not connected to chess server"
        case .serverError(let m):   return "Server error: \(m)"
        case .timeout:              return "Engine timed out"
        case .decodingFailed:       return "Failed to decode server response"
        }
    }
}

// MARK: - WDL

struct WDLResponse: Decodable {
    let white: Double
    let draw:  Double
    let black: Double
}

// MARK: - Wire responses

struct NNUETerm: Decodable {
    let white: Double
    let black: Double
    let total: Double
}

struct AnalysisResponse: Decodable {
    // ── Core (both modes) ────────────────────────────────────────────────────
    let type:             String
    let fen:              String?
    let bestmove:         String?
    let from:             String?
    let to:               String?
    let promotion:        String?
    let score_cp:         Int?
    let score_mate:       Int?
    let pv:               [String]?
    let depth:            Int?
    let nodes:            Int?
    let score_drift:      Int?
    let wdl:              WDLResponse?
    let feedback:         String?
    let message:          String?
    let alternatives:     [AlternativeMoveResponse]?
    let characteristics:  PositionCharacteristics?
    // python-chess (free, both modes)
    let material_balance: Int?
    let mobility_white:   Int?
    let mobility_black:   Int?
    let game_phase:       String?
    // Secondary engine score for comparison
    let deep_score_cp:    Int?

    // ── Analysis mode only ───────────────────────────────────────────────────
    // NNUE term breakdown from Stockfish
    let nnue:             [String: NNUETerm]?
    // Pawn structure
    let isolated_white:   Int?
    let isolated_black:   Int?
    let doubled_white:    Int?
    let doubled_black:    Int?
    let passed_white:     Int?
    let passed_black:     Int?
    let pawn_structure:   String?   // "Open" | "Semi-open" | "Closed" | "Weakened" | "Endgame-like"
    // King safety
    let king_attackers_white: Int?
    let king_attackers_black: Int?
    let king_castled_white:   Bool?
    let king_castled_black:   Bool?
}

struct AlternativeMoveResponse: Decodable {
    let rank:       Int
    let move:       String?
    let from:       String?
    let to:         String?
    let promotion:  String?
    let score_cp:   Int?
    let score_mate: Int?
    let pv:         [String]?
}

struct EngineMoveResponse: Decodable {
    let type:       String
    let move:       String?
    let from:       String?
    let to:         String?
    let promotion:  String?
    let score_cp:   Int?
    let score_mate: Int?
    let pv:         [String]?
    let message:    String?
}

// MARK: - Engine discovery

struct EnginesResponse: Decodable {
    let type:    String
    let engines: [String]
    let primary: String
}

// MARK: - Internal helper

struct TypeOnlyResponse: Decodable {
    let type: String
}
