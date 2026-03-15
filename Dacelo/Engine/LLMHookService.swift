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
// To add a new provider (e.g. OpenAI-compatible API):
//   1. Conform to LLMHookProvider
//   2. Call LLMHookService.shared.configure(provider:) in DaceloApp.init()
//
// The LLM is ONLY called when GameMode == .analysisOnly.
// In regular vs-engine or two-player games it is never triggered.

import Foundation
import Combine

// MARK: - Context Bundle
//
// Everything the LLM receives to produce its narrative.
// Populated by AnalysisStore after each move in analysis mode.

struct LLMAnalysisContext: Codable {
    let fen:              String
    let movePlayed:       String       // UCI e.g. "e2e4"
    let side:             String       // "white" | "black"
    let moveNotation:     String       // "1." | "3..."
    let wdl:              WDLContext?
    let scoreCP:          Int?
    let confidence:       String       // "Confident" | "Uncertain" | "Volatile"
    let pvLine:           [String]     // engine's top line (UCI)
    let materialBalance:  Int          // white-positive, in pawn units
    let mobilityWhite:    Int
    let mobilityBlack:    Int
    let moveClassification: String     // "Excellent" | "Good" | "Inaccuracy" etc.
    let cpLoss:           Int?         // centipawns lost vs best move
    let sharpness:        String       // "Quiet" | "Balanced" | "Tactical" | "Sharp"
    let difficulty:       String       // "Beginner" | "Intermediate" | "Advanced" | "Expert"
    let lineType:         String       // "Forcing" | "Tactical" | "Committal" | "Flexible" | "Quiet"
    let alternatives:     [LLMAlternative]
    let depth:            Int?
    let nodes:            Int?
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
    let move:    String   // UCI
    let scoreCP: Int?
}

// MARK: - Provider Protocol

protocol LLMHookProvider: AnyObject {
    /// Display name shown in settings.
    var name: String { get }
    /// Whether the provider can currently accept requests.
    var isAvailable: Bool { get async }
    /// Produce a narrative string from the context bundle.
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

// MARK: - Disabled Provider (default, no-op)

final class DisabledLLMProvider: LLMHookProvider {
    let name = "Disabled"
    var isAvailable: Bool { get async { false } }
    func analyse(context: LLMAnalysisContext) async throws -> String { "" }
}

// MARK: - Local LLM Provider (Ollama-compatible)
//
// Works with any Ollama-compatible server (Ollama, LM Studio, llama.cpp server).
// Default endpoint: http://localhost:11434  (standard Ollama)
// Default model:    llama3
//
// To use with LM Studio: set endpoint to http://localhost:1234, model to whatever
// you have loaded.

final class LocalLLMProvider: LLMHookProvider {
    let name: String
        
    // 1. Hold a reference to your settings store
    let settings: AppSettings

    // 2. Pass AppSettings into the initializer instead of strings
    init(name: String = "Local LLM", settings: AppSettings) {
        self.name     = name
        self.settings = settings
    }

    // 3. Make endpoint and model computed properties so they always fetch the latest value
    var endpoint: String { settings.llmEndpoint } // Replace with your actual property name in AppSettings
    var model: String { settings.llmModel }       // Replace with your actual property name in AppSettings

    var isAvailable: Bool {
        get async {
            // This now automatically uses the `endpoint` from your settings!
            guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
    }

    func analyse(context: LLMAnalysisContext) async throws -> String {
        guard let url = URL(string: "\(endpoint)/api/generate") else {
            throw LLMError.invalidEndpoint(endpoint)
        }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model":  model,
            "prompt": buildPrompt(context: context),
            "stream": false,
            "options": [
                "temperature": 0.4,   // low temp for factual chess analysis
                "num_predict": 150    // ~2-3 sentences
            ]
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

    // MARK: Prompt builder

    private func buildPrompt(context: LLMAnalysisContext) -> String {
        var lines: [String] = [
            "You are a chess coach giving concise, insightful move commentary.",
            "Respond in exactly 2-3 sentences. Be specific and chess-focused. No preamble.",
            "",
            "Position after \(context.side.capitalized)'s move \(context.moveNotation) (UCI: \(context.movePlayed)):",
            "FEN: \(context.fen)",
            "Move quality: \(context.moveClassification)",
        ]

        if let cp = context.cpLoss, cp > 0 {
            lines.append("Centipawn loss: \(cp)cp")
        }
        if let cp = context.scoreCP {
            lines.append(String(format: "Evaluation: %+.2f pawns (white-positive)", Double(cp) / 100.0))
        }
        if let wdl = context.wdl {
            lines.append("Win probability: White \(wdl.whitePercent)%  Draw \(wdl.drawPercent)%  Black \(wdl.blackPercent)%")
        }

        let matDesc = context.materialBalance == 0
            ? "Material is equal"
            : (context.materialBalance > 0 ? "White" : "Black") + " is up \(abs(context.materialBalance)) pawn equivalent(s)"
        lines.append(matDesc)

        lines.append("Position character: \(context.sharpness), \(context.difficulty) difficulty, \(context.lineType) line")
        lines.append("Engine confidence: \(context.confidence)")

        if !context.pvLine.isEmpty {
            let pvStr = context.pvLine.prefix(5).joined(separator: " ")
            lines.append("Engine's best continuation: \(pvStr)")
        }
        if !context.alternatives.isEmpty {
            let altStr = context.alternatives.prefix(2)
                .compactMap { alt -> String? in
                    guard let cp = alt.scoreCP else { return alt.move }
                    return "\(alt.move) (\(String(format: "%+.2f", Double(cp)/100.0)))"
                }
                .joined(separator: ", ")
            lines.append("Alternative moves: \(altStr)")
        }

        lines.append("")
        lines.append("Provide your 2-3 sentence analysis:")
        return lines.joined(separator: "\n")
    }
}

// MARK: - LLM Hook Service

@MainActor
final class LLMHookService: ObservableObject {

    static let shared = LLMHookService()

    @Published var isAnalysing:    Bool   = false
    @Published var lastNarrative:  String = ""
    @Published var providerName:   String = "Disabled"
    @Published var isAvailable:    Bool   = false

    private var provider: LLMHookProvider = DisabledLLMProvider()
    private var availabilityTask: Task<Void, Never>?

    private init() {}

    // MARK: - Configuration

    /// Call this from DaceloApp.init() or AppStore.init() to set the active provider.
    func configure(provider: LLMHookProvider) {
        self.provider     = provider
        self.providerName = provider.name
        checkAvailability()
    }

    func checkAvailability() {
        availabilityTask?.cancel()
        availabilityTask = Task {
            let available  = await provider.isAvailable
            isAvailable    = available
        }
    }

    // MARK: - Analysis

    /// Called by AnalysisStore after each move when GameMode == .analysisOnly.
    func analyse(context: LLMAnalysisContext) {
        guard isAvailable else { return }
        lastNarrative = ""
        isAnalysing   = true

        Task {
            defer { isAnalysing = false }
            do {
                lastNarrative = try await provider.analyse(context: context)
            } catch {
                print("[LLMHookService] Analysis failed: \(error.localizedDescription)")
                lastNarrative = ""
            }
        }
    }

    func clearNarrative() {
        lastNarrative = ""
    }
}
