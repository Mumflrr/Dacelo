// AppSettings.swift
// Dacelo

import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverHost")           var serverHost:           String = "your-pc-hostname"
    @AppStorage("serverPort")           var serverPort:           Int    = 8765
    @AppStorage("moveTimeMs")           var moveTimeMs:           Int    = 3000
    @AppStorage("showBestMoveArrow")    var showBestMoveArrow:    Bool   = true
    @AppStorage("hintCount")            var hintCount:            Int    = 1
    @AppStorage("pieceSetName")         var pieceSetName:         String = "cburnett"

    // ── Stockfish ─────────────────────────────────────────────────────────────
    /// Use Stockfish for centipawn score instead of lc0.
    @AppStorage("useStockfishEval")     var useStockfishEval:     Bool   = false
    /// Use Stockfish for best move suggestion instead of lc0.
    @AppStorage("useStockfishBestMove") var useStockfishBestMove: Bool   = false

    // ── LLM ───────────────────────────────────────────────────────────────────
    @AppStorage("llmEndpoint")          var llmEndpoint:          String = "http://localhost:11434"
    @AppStorage("llmModel")             var llmModel:             String = "llama3"

    var pieceSet: PieceSet { PieceSet(rawValue: pieceSetName) ?? .cburnett }
}
