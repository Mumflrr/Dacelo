// EngineModels.swift
// Dacelo
//
// All response types decoded from the lc0 WebSocket server.

import Foundation

// MARK: - Errors

enum EngineError: LocalizedError {
    case notConnected
    case serverError(String)
    case timeout
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:         return "Not connected to lc0 server"
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

struct AnalysisResponse: Decodable {
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
    /// Max centipawn drift across search depths — measures engine confidence.
    let score_drift:      Int?
    /// Win/Draw/Loss probabilities from lc0's neural network (0.0–1.0 each).
    let wdl:              WDLResponse?
    /// Material balance in pawn units, white-positive.
    let material_balance: Int?
    /// Legal move count for each side — proxy for piece activity.
    let mobility_white:   Int?
    let mobility_black:   Int?
    let feedback:         String?
    let message:          String?
    let alternatives:     [AlternativeMoveResponse]?
    let characteristics:  PositionCharacteristics?
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

// MARK: - Internal helper

struct TypeOnlyResponse: Decodable {
    let type: String
}
