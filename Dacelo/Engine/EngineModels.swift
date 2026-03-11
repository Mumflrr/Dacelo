// EngineModels.swift
// Dacelo
//
// All response types decoded from the lc0 WebSocket server.
// Kept separate so EngineService, AnalysisStore, and GameStore
// can all import them without circular dependencies.

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

// MARK: - Wire responses

struct AnalysisResponse: Decodable {
    let type: String
    let fen: String?
    let bestmove: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
    let pv: [String]?
    let depth: Int?
    let nodes: Int?
    let feedback: String?
    let message: String?
    let alternatives: [AlternativeMoveResponse]?
    let characteristics: PositionCharacteristics?
}

struct AlternativeMoveResponse: Decodable {
    let rank: Int
    let move: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
}

struct EngineMoveResponse: Decodable {
    let type: String
    let move: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
    let pv: [String]?
    let message: String?
}

// MARK: - Internal helper

struct TypeOnlyResponse: Decodable {
    let type: String
}
