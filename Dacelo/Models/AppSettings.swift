// AppSettings.swift
// Dacelo
import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverHost")        var serverHost:        String = "your-pc-hostname"
    @AppStorage("serverPort")        var serverPort:        Int    = 1024
    @AppStorage("showBestMoveArrow") var showBestMoveArrow: Bool   = true
    @AppStorage("hintCount")         var hintCount:         Int    = 1
    @AppStorage("pieceSetName")      var pieceSetName:      String = "cburnett"

    // ── Engine selection ──────────────────────────────────────────────────────
    @AppStorage("evalEngine")        var evalEngine:        String = "stockfish"
    @AppStorage("bestMoveEngine")    var bestMoveEngine:    String = "lc0"
    @AppStorage("nnueEngine")        var nnueEngine:        String = "stockfish"
    @AppStorage("moveTimeMs")        var moveTimeMs:        Int    = 1000
    @AppStorage("evalTimeMs")        var evalTimeMs:        Int    = 2000

    // ── Available engines (populated from server on connect) ──────────────────
    @Published var availableEngines: [String] = []

    // ── LLM ───────────────────────────────────────────────────────────────────
    @AppStorage("llmEndpoint")       var llmEndpoint:       String = "http://localhost:11434"
    @AppStorage("llmModel")          var llmModel:          String = "llama3"

    // ── Clock ─────────────────────────────────────────────────────────────────
    // Stored as index into TimeControl.presets so @AppStorage can handle it.
    @AppStorage("timeControlIndex")  var timeControlIndex:  Int    = 0

    var timeControl: TimeControl {
        get { TimeControl.presets[min(timeControlIndex, TimeControl.presets.count - 1)] }
        set { timeControlIndex = TimeControl.presets.firstIndex(of: newValue) ?? 0 }
    }

    // ── Difficulty ────────────────────────────────────────────────────────────
    // 0.0 = complete beginner (random legal moves, ignores engine)
    // 1.0 = full engine strength (always plays best move)
    // Stored as Int (0–100) so @AppStorage can handle it.
    @AppStorage("difficultyPct")     var difficultyPct:     Int    = 80

    var difficulty: Double { Double(difficultyPct) / 100.0 }

    // Number of opening moves where book randomisation applies.
    // At high difficulty the engine plays the book correctly.
    // At low difficulty it plays random legal moves in the opening.
    @AppStorage("openingMovesDepth") var openingMovesDepth: Int    = 8

    var pieceSet: PieceSet { PieceSet(rawValue: pieceSetName) ?? .cburnett }
}
