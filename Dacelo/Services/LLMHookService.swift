// LLMHookService.swift
// Dacelo
//
// Protocol-based LLM hook system for chess analysis narrative.
//
// Architecture:
//   LLMHookProvider  — protocol any LLM backend implements
//   LocalLLMProvider — Ollama-compatible implementation (default)
//   LLMHookService   — @MainActor singleton that AnalysisStore calls
//
// Narrative generation is FIRE-AND-STORE, PER-MOVE:
//   • LLM calls fire immediately as each move is analysed (background, silent).
//   • Each MoveCritique gets its own narrative stored by UUID in `narratives`.
//   • Nothing is displayed until the user enters Analysis Mode and selects a move.
//   • A per-move loading indicator shows while a narrative is in-flight.
//   • fillMissingNarratives() catches any that failed (e.g. LLM was offline).
//
// To add a new provider (e.g. OpenAI-compatible API):
//   1. Conform to LLMHookProvider
//   2. Call LLMHookService.shared.configure(provider:) in AppStore.init()

import Foundation
import Combine

// MARK: - Context Bundle

struct LLMAnalysisContext: Codable {
    let fen:                String
    let movePlayed:         String       // UCI e.g. "e2e4"
    let side:               String       // "white" | "black"
    let moveNotation:       String       // "1." | "3..."
    let wdl:                WDLContext?
    let scoreCP:            Int?
    let pvLine:             [String]
    let materialBalance:    Int
    let mobilityWhite:      Int
    let mobilityBlack:      Int
    let moveClassification: String
    let cpLoss:             Int?
    // Updated field names matching PositionCharacteristics
    let positionType:       String       // "Equal"|"Unbalanced"|"Complex"|"Critical"
    let precisionRequired:  String       // "Low"|"Moderate"|"High"|"Very High"
    let evalStability:      String       // "Stable"|"Fluctuating"|"Volatile"
    let lineType:           String
    let alternatives:       [LLMAlternative]
    let depth:              Int?
    let nodes:              Int?
    // Game phase context
    let gamePhase:          String?      // "Opening"|"Middlegame"|"Endgame"
    // New metrics (analysis mode)
    let pawnStructure:      String?      // "Open"|"Closed"|"Semi-open"|"Weakened"|"Endgame-like"
    let passedWhite:        Int?
    let passedBlack:        Int?
    let isolatedWhite:      Int?
    let isolatedBlack:      Int?
    let kingAttackersWhite: Int?
    let kingAttackersBlack: Int?
    let kingCastledWhite:   Bool?
    let kingCastledBlack:   Bool?
    // NNUE key terms (the most coaching-relevant ones, not the full dump)
    let nnueKingSafety:     NNUETermContext?
    let nnueMobility:       NNUETermContext?
    let nnueThreats:        NNUETermContext?
    let nnuePassedPawns:    NNUETermContext?
}

struct NNUETermContext: Codable {
    let white: Double
    let black: Double
    let total: Double
}

struct WDLContext: Codable {
    let white: Double
    let draw:  Double
    let black: Double

    var whitePercent: Int { Int((white * 100).rounded()) }
    var drawPercent:  Int { Int((draw  * 100).rounded()) }
    var blackPercent: Int { Int((black * 100).rounded()) }
}

struct LLMAlternative: Codable {
    let move:    String
    let scoreCP: Int?
}

// MARK: - Provider Protocol

protocol LLMHookProvider: AnyObject {
    var name:        String { get }
    var isAvailable: Bool   { get async }
    func analyse(context: LLMAnalysisContext) async throws -> String
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case providerUnavailable
    case invalidEndpoint(String)
    case httpError(Int)
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:      return "LLM provider is not available"
        case .invalidEndpoint(let u):   return "Invalid LLM endpoint: \(u)"
        case .httpError(let code):      return "LLM HTTP error \(code)"
        case .invalidResponse:          return "Unexpected response format from LLM"
        case .emptyResponse:            return "LLM returned an empty response"
        }
    }
}

// MARK: - Disabled Provider

final class DisabledLLMProvider: LLMHookProvider {
    let name = "Disabled"
    var isAvailable: Bool { get async { false } }
    func analyse(context: LLMAnalysisContext) async throws -> String { "" }
}

// MARK: - Local LLM Provider (Ollama/llama.cpp-compatible)

final class LocalLLMProvider: LLMHookProvider {
    let name:     String
    let settings: AppSettings

    init(name: String = "Local LLM", settings: AppSettings) {
        self.name     = name
        self.settings = settings
    }

    var endpoint: String { settings.llmEndpoint }
    var model:    String { settings.llmModel }

    var isAvailable: Bool {
        get async {
            guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }
    }

    func analyse(context: LLMAnalysisContext) async throws -> String {
        guard let url = URL(string: "\(endpoint)/api/generate") else {
            throw LLMError.invalidEndpoint(endpoint)
        }
        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60   // longer for analysis-mode detail

        let body: [String: Any] = [
            "model":  model,
            "prompt": buildPrompt(context: context),
            "stream": false,
            "options": ["temperature": 0.4, "num_predict": 200]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMError.httpError(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw LLMError.invalidResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LLMError.emptyResponse }
        return trimmed
    }

    // MARK: - Prompt builder
    //
    // The prompt is enriched with all available context so the LLM can give
    // specific coaching feedback ("your king has 3 attackers because you
    // haven't castled") rather than generic observations.

    private func buildPrompt(context: LLMAnalysisContext) -> String {
        var lines: [String] = [
            "You are a chess coach giving concise, specific move commentary for a student reviewing their game.",
            "Respond in 2-3 sentences. Reference concrete details from the position. No preamble or filler phrases.",
            "",
            "Move: \(context.side.capitalized) played \(context.moveNotation) (UCI: \(context.movePlayed))",
            "FEN: \(context.fen)",
            "Quality: \(context.moveClassification)",
        ]

        if let cp = context.cpLoss, cp > 0 {
            lines.append("Centipawn loss vs best: \(cp)cp")
        }
        if let cp = context.scoreCP {
            lines.append(String(format: "Evaluation: %+.2f (white-positive)", Double(cp) / 100.0))
        }
        if let wdl = context.wdl {
            lines.append("Win probability: White \(wdl.whitePercent)%  Draw \(wdl.drawPercent)%  Black \(wdl.blackPercent)%")
        }
        if let phase = context.gamePhase {
            lines.append("Game phase: \(phase)")
        }

        // Material
        let mat = context.materialBalance
        lines.append(mat == 0 ? "Material: equal"
            : (mat > 0 ? "White" : "Black") + " is up \(abs(mat)) pawn equivalent(s)")

        // Position character
        lines.append("Position: \(context.positionType), precision required: \(context.precisionRequired), \(context.lineType) line")
        lines.append("Eval stability: \(context.evalStability)")

        // Pawn structure
        if let structure = context.pawnStructure {
            var pawnLines = ["Pawn structure: \(structure)"]
            if let iw = context.isolatedWhite, iw > 0 { pawnLines.append("White isolated: \(iw)") }
            if let ib = context.isolatedBlack, ib > 0 { pawnLines.append("Black isolated: \(ib)") }
            if let pw = context.passedWhite,   pw > 0 { pawnLines.append("White passed: \(pw)") }
            if let pb = context.passedBlack,   pb > 0 { pawnLines.append("Black passed: \(pb)") }
            lines.append(pawnLines.joined(separator: " | "))
        }

        // King safety — one of the most useful coaching cues
        let wAtk = context.kingAttackersWhite ?? 0
        let bAtk = context.kingAttackersBlack ?? 0
        let wCas = context.kingCastledWhite == true
        let bCas = context.kingCastledBlack == true
        if wAtk > 0 || bAtk > 0 || !wCas || !bCas {
            lines.append("King safety: White king \(wCas ? "castled" : "uncastled"), \(wAtk) attacker(s) in zone; Black king \(bCas ? "castled" : "uncastled"), \(bAtk) attacker(s) in zone")
        }

        // NNUE terms — give the LLM the Stockfish breakdown if available
        var nnueLines: [String] = []
        if let ks = context.nnueKingSafety {
            nnueLines.append(String(format: "King Safety: W%+.2f B%+.2f", ks.white, ks.black))
        }
        if let mob = context.nnueMobility {
            nnueLines.append(String(format: "Mobility: W%+.2f B%+.2f", mob.white, mob.black))
        }
        if let thr = context.nnueThreats {
            nnueLines.append(String(format: "Threats: W%+.2f B%+.2f", thr.white, thr.black))
        }
        if let pp = context.nnuePassedPawns {
            nnueLines.append(String(format: "Passed Pawns: W%+.2f B%+.2f", pp.white, pp.black))
        }
        if !nnueLines.isEmpty {
            lines.append("NNUE breakdown: " + nnueLines.joined(separator: " | "))
        }

        // Engine lines
        if !context.pvLine.isEmpty {
            lines.append("Best continuation: " + context.pvLine.prefix(5).joined(separator: " "))
        }
        if !context.alternatives.isEmpty {
            let altStr = context.alternatives.prefix(2)
                .compactMap { alt -> String? in
                    guard let cp = alt.scoreCP else { return alt.move }
                    return "\(alt.move) (\(String(format: "%+.2f", Double(cp)/100.0)))"
                }
                .joined(separator: ", ")
            lines.append("Alternatives: \(altStr)")
        }

        lines.append("")
        lines.append("Coach your student about this move:")
        return lines.joined(separator: "\n")
    }
}

// MARK: - LLM Hook Service

@MainActor
final class LLMHookService: ObservableObject {

    static let shared = LLMHookService()

    @Published var providerName:   String              = "Disabled"
    @Published var isAvailable:    Bool                = false

    // Per-move narrative storage. Key = MoveCritique.id
    // Stored here (not on MoveCritique) so async fills don't require mutating Codable structs.
    @Published var narratives:     [UUID: String]      = [:]
    @Published var generating:     Set<UUID>           = []   // which moves are in-flight

    private var provider: LLMHookProvider = DisabledLLMProvider()
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
        availabilityTask = Task {
            isAvailable = await provider.isAvailable
        }
    }

    // MARK: - Per-move narrative access

    /// Whether a narrative has been generated for this critique.
    func hasNarrative(for id: UUID) -> Bool {
        narratives[id] != nil
    }

    /// Whether generation is currently in-flight for this critique.
    func isGenerating(for id: UUID) -> Bool {
        generating.contains(id)
    }

    /// The narrative for a specific critique, or nil if not yet generated.
    func narrative(for id: UUID) -> String? {
        narratives[id]
    }

    // MARK: - Generation
    //
    // Fire-and-store: called immediately as each move is analysed during play.
    // The narrative is stored silently — nothing is displayed until review mode.
    // This means by the time the user enters review, most moves already have
    // commentary ready.

    /// Fire narrative generation for one critique. Idempotent — safe to call
    /// multiple times; skips if already generated or in-flight.
    func requestNarrative(for critiqueID: UUID, context: LLMAnalysisContext) {
        guard isAvailable else { return }
        guard narratives[critiqueID] == nil else { return }
        guard !generating.contains(critiqueID) else { return }

        generating.insert(critiqueID)
        Task {
            defer { generating.remove(critiqueID) }
            do {
                narratives[critiqueID] = try await provider.analyse(context: context)
            } catch {
                print("[LLMHookService] Failed for \(critiqueID): \(error.localizedDescription)")
            }
        }
    }

    /// Convenience: fire for all critiques that don't yet have a narrative.
    /// Used when entering review mode to fill any gaps (e.g. LLM was offline during play).
    func fillMissingNarratives(critiques: [(id: UUID, context: LLMAnalysisContext)]) {
        guard isAvailable else { return }
        for (id, ctx) in critiques {
            requestNarrative(for: id, context: ctx)
        }
    }

    func clearNarratives() {
        narratives.removeAll()
        generating.removeAll()
    }
}
