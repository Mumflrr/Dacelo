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
    @AppStorage("moveTimeMs")        var moveTimeMs:        Int    = 3000
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

    var pieceSet: PieceSet { PieceSet(rawValue: pieceSetName) ?? .cburnett }
}
