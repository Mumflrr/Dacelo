// DaceloApp.swift
// Dacelo

import SwiftUI

@main
struct DaceloApp: App {
    @StateObject private var app = AppStore()

    init() {
        // Configure LLM — swap LocalLLMProvider for any other conforming provider
        LLMHookService.shared.configure(
            provider: LocalLLMProvider(
                endpoint: "http://localhost:11434",
                model: "llama3"
            )
        )
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.gameStore)
                .environmentObject(app.analysis)
                .environmentObject(app.settings)
                .environmentObject(app.engineState)  // EngineConnectionState for UI
        }
    }
}
