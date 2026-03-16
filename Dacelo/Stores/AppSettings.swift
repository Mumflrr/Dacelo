// AppSettings.swift
// Dacelo

import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverHost")        var serverHost:        String = "your-pc-hostname"
    @AppStorage("serverPort")        var serverPort:        Int    = 8765
    @AppStorage("showBestMoveArrow") var showBestMoveArrow: Bool   = true
    @AppStorage("hintCount")         var hintCount:         Int    = 1
    @AppStorage("pieceSetName")      var pieceSetName:      String = "cburnett"

    // ── Engine selection ──────────────────────────────────────────────────────
    /// Name of the engine used for all analysis (score, alternatives, NNUE, WDL).
    /// Should be Stockfish for a training app — it provides named eval terms and
    /// calibrated WDL that lc0 cannot match for explainability.
    @AppStorage("evalEngine")        var evalEngine:        String = "stockfish"

    /// Engine that generates the opponent's moves. Can differ from evalEngine —
    /// e.g. play against lc0 but analyse with Stockfish.
    @AppStorage("bestMoveEngine")    var bestMoveEngine:    String = "lc0"

    /// Engine that runs concurrently in Analysis Mode to provide NNUE term
    /// breakdowns (King Safety, Threats, Passed Pawns, etc.).
    /// Must emit `info string` NNUE lines — i.e. must be Stockfish or compatible.
    @AppStorage("nnueEngine")        var nnueEngine:        String = "stockfish"

    /// Milliseconds the move engine is allowed to think per move.
    @AppStorage("moveTimeMs")        var moveTimeMs:        Int    = 3000

    /// Milliseconds the eval engine is allowed to think per position.
    /// Can be longer than moveTimeMs since it runs after the move, not during.
    @AppStorage("evalTimeMs")        var evalTimeMs:        Int    = 2000

    // ── Available engines (populated from server on connect) ──────────────────
    /// Live list of engine names the server has registered.
    /// Empty until the first successful `engines` query.
    /// Not persisted — refreshed each session.
    @Published var availableEngines: [String] = []

    // ── LLM ───────────────────────────────────────────────────────────────────
    @AppStorage("llmEndpoint")       var llmEndpoint:       String = "http://localhost:11434"
    @AppStorage("llmModel")          var llmModel:          String = "llama3"

    var pieceSet: PieceSet { PieceSet(rawValue: pieceSetName) ?? .cburnett }
}
