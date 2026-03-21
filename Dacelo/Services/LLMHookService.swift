// LLMHookService.swift
// Dacelo
//
// Protocol-based LLM hook system for chess analysis narrative.
//
// Architecture:
//   LLMHookProvider    — protocol any LLM backend implements
//   LocalLLMProvider   — Ollama/llama.cpp-compatible implementation
//   LLMHookService     — @MainActor singleton that AnalysisStore calls
//
// Output is structured (ChessCoachingOutput), not a raw string.
// The LLM is prompted to return JSON with four named fields.
// AnalysisPanelViews renders each field separately with icons/styling.
//
// Two modes:
//   fast — short thinking budget, 3-sentence max, fires for every move
//   slow — full thinking budget, fires only for flagged moves
//          (blunders >150cp, unusual depth drift, sacrifices)
//
// Prompt design:
//   Raw numbers are pre-digested into human-readable flags on the Swift
//   side before sending. No NNUE floats, no mobility integers.
//   ~120-160 tokens of dense, directly-readable context per request.
//   NoWait logit suppression applied to cut reflection token overhead.

import Foundation
import Combine
import SwiftUI

// MARK: - Structured output

/// Three-field structured coaching response stored per move.
/// Each field has a specific job and is rendered separately in the UI.
struct ChessCoachingOutput: Codable {
    /// One sentence: what happened and its immediate consequence.
    let headline: String

    /// One sentence: the concrete tactical or positional reason.
    let explanation: String

    /// One sentence: what to play instead and why.
    /// nil for Excellent / Good moves — omit the JSON key for those.
    let suggestion: String?

    /// Primary pattern tag. Drives the badge icon shown next to the narrative.
    /// One of the values in TacticalPattern below.
    let tacticalPattern: String
}

/// All valid tactical pattern tags, with display metadata.
enum TacticalPattern: String {
    case fork             = "fork"
    case pin              = "pin"
    case skewer           = "skewer"
    case discoveredAttack = "discovered_attack"
    case backRank         = "back_rank"
    case kingSafety       = "king_safety"
    case development      = "development"
    case pawnStructure    = "pawn_structure"
    case materialGain     = "material_gain"
    case zugzwang         = "zugzwang"
    case passedPawn       = "passed_pawn"
    case sacrifice        = "sacrifice"
    case blunder          = "blunder"
    case bestMove         = "best_move"
    case other            = "other"

    var icon: String {
        switch self {
        case .fork:             return "arrow.triangle.branch"
        case .pin:              return "pin.fill"
        case .skewer:           return "arrow.right.arrow.left"
        case .discoveredAttack: return "bolt.fill"
        case .backRank:         return "exclamationmark.square.fill"
        case .kingSafety:       return "crown.fill"
        case .development:      return "figure.walk"
        case .pawnStructure:    return "triangle.fill"
        case .materialGain:     return "plus.circle.fill"
        case .zugzwang:         return "tortoise.fill"
        case .passedPawn:       return "arrow.up.to.line"
        case .sacrifice:        return "flame.fill"
        case .blunder:          return "xmark.circle.fill"
        case .bestMove:         return "checkmark.circle.fill"
        case .other:            return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .blunder:                    return .red
        case .bestMove:                   return .green
        case .sacrifice:                  return .orange
        case .fork, .pin, .skewer,
             .discoveredAttack, .backRank: return .yellow
        case .kingSafety:                 return Color(red: 1, green: 0.3, blue: 0.3)
        case .materialGain:               return Color(red: 0.4, green: 0.9, blue: 0.4)
        default:                          return .purple
        }
    }

    static func from(_ raw: String) -> TacticalPattern {
        TacticalPattern(rawValue: raw) ?? .other
    }
}

extension ChessCoachingOutput {
    var pattern: TacticalPattern { TacticalPattern.from(tacticalPattern) }
}

// MARK: - Request type
//
// Replaces LLMAnalysisContext. Pre-digested on the Swift side.
// AnalysisStore builds this after every move and stores it keyed by UUID.

struct ChessCoachingRequest: Codable {

    // ── Move identity ────────────────────────────────────────────────────
    let movePlayed:   String   // UCI: "e2e4"
    let side:         String   // "white" | "black"
    let moveNotation: String   // "1." | "3..."
    let classification: String // MoveQuality.rawValue: "Excellent" | "Good" etc.

    // ── Score & stakes ────────────────────────────────────────────────────
    let cpLoss:      Int?      // centipawns lost vs best (nil if best move)
    let evalAfter:   Double?   // eval after move in pawns (white-positive)
    let winPctWhite: Int?
    let winPctDraw:  Int?
    let winPctBlack: Int?
    let gamePhase:   String?   // "Opening" | "Middlegame" | "Endgame"
    let materialDelta: Int     // positive = white ahead in material

    // ── Best alternative ─────────────────────────────────────────────────
    // The single most important field for "why X was better" coaching.
    let bestMove:      String?   // UCI of best move if different from played
    let bestMoveEval:  Double?   // eval of best move in pawns

    // ── Engine continuation ───────────────────────────────────────────────
    // First 4 moves of PV in human-readable notation (pre-converted)
    let bestLine: [String]

    // ── Depth profile ─────────────────────────────────────────────────────
    // Derived on Swift side from score_cp vs deep_score_cp.
    // nil if no deep score available.
    // "stable" | "deepening" | "mirage" | "sharp"
    let depthProfile: String?

    // ── Pre-digested tactical flags ───────────────────────────────────────
    // Computed from raw server data before sending. Each is a plain English
    // phrase the LLM reads directly — no number interpretation needed.
    // Examples: "White king uncastled with 3 attackers in zone"
    //           "Black has a passed pawn on d4"
    //           "White is up a rook"
    let tacticalFlags: [String]

    // ── Mode ──────────────────────────────────────────────────────────────
    let isSlowMode: Bool
}

// MARK: - WDL / Alternative types (unchanged, used by AnalysisStore)

struct WDLContext: Codable {
    let white: Double; let draw: Double; let black: Double
    var whitePercent: Int { Int((white * 100).rounded()) }
    var drawPercent:  Int { Int((draw  * 100).rounded()) }
    var blackPercent: Int { Int((black * 100).rounded()) }
}

struct LLMAlternative: Codable {
    let move: String; let scoreCP: Int?
}

struct NNUETermContext: Codable {
    let white: Double; let black: Double; let total: Double
}

// Legacy alias so any remaining AnalysisStore call sites compile unchanged
typealias LLMAnalysisContext = ChessCoachingRequest

// MARK: - Provider protocol

protocol LLMHookProvider: AnyObject {
    var name:        String { get }
    var isAvailable: Bool   { get async }
    func analyse(request: ChessCoachingRequest) async throws -> ChessCoachingOutput
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case providerUnavailable
    case invalidEndpoint(String)
    case httpError(Int)
    case invalidResponse
    case emptyResponse
    case parseFailure(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:    return "LLM provider is not available"
        case .invalidEndpoint(let u): return "Invalid LLM endpoint: \(u)"
        case .httpError(let c):       return "LLM HTTP error \(c)"
        case .invalidResponse:        return "Unexpected LLM response format"
        case .emptyResponse:          return "LLM returned empty response"
        case .parseFailure(let s):    return "Parse failed: \(s)"
        }
    }
}

// MARK: - Disabled provider

final class DisabledLLMProvider: LLMHookProvider {
    let name = "Disabled"
    var isAvailable: Bool { get async { false } }
    func analyse(request: ChessCoachingRequest) async throws -> ChessCoachingOutput {
        throw LLMError.providerUnavailable
    }
}

// MARK: - Local LLM provider (Ollama / llama.cpp compatible)

final class LocalLLMProvider: LLMHookProvider {
    let name: String
    let settings: AppSettings

    init(name: String = "Local LLM", settings: AppSettings) {
        self.name = name; self.settings = settings
    }

    private var endpoint: String { settings.llmEndpoint }
    private var model:    String { settings.llmModel }

    var isAvailable: Bool {
        get async {
            guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
            do {
                let (_, res) = try await URLSession.shared.data(from: url)
                return (res as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }
    }

    func analyse(request: ChessCoachingRequest) async throws -> ChessCoachingOutput {
        guard let url = URL(string: "\(endpoint)/api/generate") else {
            throw LLMError.invalidEndpoint(endpoint)
        }
        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = request.isSlowMode ? 90 : 45

        let body: [String: Any] = [
            "model":   model,
            "prompt":  buildPrompt(request),
            "stream":  false,
            "options": [
                "temperature": request.isSlowMode ? 0.3 : 0.4,
                "num_predict": request.isSlowMode ? 350 : 200,
                // NoWait logit suppression (arxiv: 2506.08343):
                // Suppress reflection tokens that pad CoT without adding value.
                // Achieves 27-51% CoT reduction on Qwen3.5 models.
                // Token IDs are Qwen3.5-specific — adapt for other models by
                // sampling 32 outputs and identifying frequent stall tokens.
                "logit_bias": noWaitBias
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw LLMError.invalidResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LLMError.emptyResponse }
        return try parseOutput(trimmed)
    }

    // MARK: - NoWait bias table (Qwen3.5 token IDs)
    private var noWaitBias: [String: Int] {
        ["14190": -100,   // "Wait"
         "27261": -100,   // "Hmm"
         "18094": -100,   // "Alternatively"
         "4354":  -100,   // "However"
         "13207": -50,    // "Actually"
         "14196": -50]    // "wait" lowercase
    }

    // MARK: - Prompt builder

    private func buildPrompt(_ r: ChessCoachingRequest) -> String {
        var lines: [String] = []

        // Role + mode
        lines.append(r.isSlowMode
            ? "You are an expert chess coach. Analyse this move in depth. Be specific about pieces and squares."
            : "You are a chess coach. Give concise, concrete move feedback.")
        lines.append("")

        // Move
        let cpStr: String = r.cpLoss.map { cp in
            cp > 0 ? String(format: " (−%.2f pawns vs best)", Double(cp)/100.0) : ""
        } ?? ""
        lines.append("Move: \(r.side.capitalized) \(r.moveNotation) \(uci(r.movePlayed)) — \(r.classification)\(cpStr)")

        // Best alternative — most critical for coaching
        if let best = r.bestMove, best != r.movePlayed {
            let ev = r.bestMoveEval.map { String(format: " (%+.2f)", $0) } ?? ""
            lines.append("Best was: \(uci(best))\(ev)")
        }

        // Position snapshot
        if let e = r.evalAfter {
            let favour = e > 0.2 ? "white favoured" : e < -0.2 ? "black favoured" : "roughly equal"
            lines.append(String(format: "Eval: %+.2f (\(favour))\(r.gamePhase.map { " | \($0)" } ?? "")", e))
        }
        if let w = r.winPctWhite, let d = r.winPctDraw, let b = r.winPctBlack {
            lines.append("Win odds: White \(w)% / Draw \(d)% / Black \(b)%")
        }
        if r.materialDelta != 0 {
            lines.append("\(r.materialDelta > 0 ? "White" : "Black") up \(abs(r.materialDelta)) pawn(s) material")
        }

        // Depth profile — only mention non-stable
        if let dp = r.depthProfile {
            switch dp {
            case "mirage":
                lines.append("⚠️ Score collapses at deeper search — hidden refutation exists")
            case "deepening":
                lines.append("✓ Score improves at depth — a forcing sequence is available")
            case "sharp":
                lines.append("⚡ Sharp — score oscillates, both sides have resources")
            default: break
            }
        }

        // Tactical flags (pre-digested, plain English)
        if !r.tacticalFlags.isEmpty {
            lines.append("Flags: " + r.tacticalFlags.joined(separator: " | "))
        }

        // Engine continuation
        if !r.bestLine.isEmpty {
            lines.append("Engine line: " + r.bestLine.prefix(4).joined(separator: " "))
        }

        // Output schema
        lines.append("")
        let schemaNote = r.isSlowMode
            ? "explanation can be two sentences for complex moves"
            : "one sentence per field"
        lines.append("""
        Respond ONLY with valid JSON (\(schemaNote), no markdown):
        {
          "headline": "<what happened and immediate consequence>",
          "explanation": "<specific tactical/positional reason — name pieces and squares>",
          "suggestion": "<what to play instead and why — OMIT this key entirely if the move was Excellent or Good>",
          "tacticalPattern": "<fork|pin|skewer|discovered_attack|back_rank|king_safety|development|pawn_structure|material_gain|zugzwang|passed_pawn|sacrifice|blunder|best_move|other>"
        }
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Output parser

    private func parseOutput(_ raw: String) throws -> ChessCoachingOutput {
        // Strip markdown fences if present
        var text = raw
        if let open = text.range(of: "```"),
           let close = text.range(of: "```", options: .backwards),
           open != close {
            let inner = text[open.upperBound..<close.lowerBound]
            text = inner.firstIndex(of: "\n").map { String(inner[inner.index(after: $0)...]) }
                ?? String(inner)
        }

        // Isolate JSON object
        guard let start = text.firstIndex(of: "{"),
              let end   = text.lastIndex(of: "}") else {
            throw LLMError.parseFailure("No JSON in: \(raw.prefix(200))")
        }
        let jsonData = Data(String(text[start...end]).utf8)

        // Strict decode first
        if let out = try? JSONDecoder().decode(ChessCoachingOutput.self, from: jsonData) {
            return out
        }

        // Lenient fallback: extract whatever keys exist
        if let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return ChessCoachingOutput(
                headline:        dict["headline"]        as? String ?? "Move played.",
                explanation:     dict["explanation"]     as? String ?? "",
                suggestion:      dict["suggestion"]      as? String,
                tacticalPattern: dict["tacticalPattern"] as? String ?? "other"
            )
        }

        throw LLMError.parseFailure(raw.prefix(200).description)
    }

    // MARK: - UCI → human notation

    private func uci(_ s: String) -> String {
        guard s.count >= 4 else { return s }
        let from  = String(s.prefix(2))
        let to    = String(s.dropFirst(2).prefix(2))
        let promo = s.count > 4 ? { switch s.last {
            case "q": return " (queen)"; case "r": return " (rook)"
            case "b": return " (bishop)"; case "n": return " (knight)"
            default:  return "" } }() : ""
        return "\(from)→\(to)\(promo)"
    }
}

// MARK: - LLM Hook Service

@MainActor
final class LLMHookService: ObservableObject {

    static let shared = LLMHookService()

    @Published var providerName: String = "Disabled"
    @Published var isAvailable:  Bool   = false

    /// Structured coaching output keyed by MoveCritique.id
    @Published var narratives: [UUID: ChessCoachingOutput] = [:]
    /// Critiques currently generating
    @Published var generating: Set<UUID> = []

    private var provider:         LLMHookProvider = DisabledLLMProvider()
    private var availabilityTask: Task<Void, Never>?

    private init() {}

    // MARK: - Configuration

    func configure(provider: LLMHookProvider) {
        self.provider     = provider
        self.providerName = provider.name
        checkAvailability()
    }

    func checkAvailability() {
        availabilityTask?.cancel()
        availabilityTask = Task { isAvailable = await provider.isAvailable }
    }

    // MARK: - Accessors

    func hasNarrative(for id: UUID) -> Bool { narratives[id] != nil }
    func isGenerating(for id: UUID) -> Bool { generating.contains(id) }
    func narrative(for id: UUID) -> ChessCoachingOutput? { narratives[id] }

    // MARK: - Generation

    /// Fire narrative for one critique. Idempotent.
    func requestNarrative(for id: UUID, context: ChessCoachingRequest) {
        guard isAvailable, narratives[id] == nil, !generating.contains(id) else { return }
        generating.insert(id)
        Task {
            defer { generating.remove(id) }
            do {
                narratives[id] = try await provider.analyse(request: context)
            } catch {
                print("[LLMHookService] \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Fill any critiques missing a narrative. Call on entering review mode.
    func fillMissingNarratives(critiques: [(id: UUID, context: ChessCoachingRequest)]) {
        guard isAvailable else { return }
        critiques.forEach { requestNarrative(for: $0.id, context: $0.context) }
    }

    func clearNarratives() {
        narratives.removeAll()
        generating.removeAll()
    }
}
