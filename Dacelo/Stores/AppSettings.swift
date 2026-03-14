// AppSettings.swift
// Dacelo
//
// All user-configurable settings in one isolated place.
// Injected as an @EnvironmentObject so any view can read/write
// without going through AppStore.

import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("serverHost")        var serverHost:        String = "your-pc-hostname"
    @AppStorage("serverPort")        var serverPort:        Int    = 8765
    @AppStorage("moveTimeMs")        var moveTimeMs:        Int    = 3000
    /// Show the best-move arrow automatically after each analysis
    @AppStorage("showBestMoveArrow") var showBestMoveArrow: Bool   = true
    /// How many best moves to show when Hint is pressed (1–3, requires MULTI_PV ≥ 3 on server)
    @AppStorage("hintCount")         var hintCount:         Int    = 1
    /// Active piece set folder name. Defaults to cburnett.
    @AppStorage("pieceSetName")      var pieceSetName:      String = "cburnett"
    @AppStorage("llmEndpoint") var llmEndpoint: String = "http://localhost:11434"
    @AppStorage("llmModel")    var llmModel:    String = "llama3"
    // Also change in LLMHookService too?

    /// Strongly-typed piece set derived from the stored raw value.
    var pieceSet: PieceSet { PieceSet(rawValue: pieceSetName) ?? .cburnett }
    
}
