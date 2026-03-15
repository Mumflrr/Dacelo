// DaceloApp.swift
// Dacelo

import SwiftUI

@main
struct DaceloApp: App {
    @StateObject private var app = AppStore()
    
    // Note: We removed the init() method because we can't access
    // the `@StateObject` properties safely before the app finishes launching.

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.gameStore)
                .environmentObject(app.analysis)
                .environmentObject(app.settings)
                .environmentObject(app.engineState)  // EngineConnectionState for UI
                .onAppear {
                    // Configure LLM as soon as the app appears,
                    // passing it the live settings from your AppStore!
                    LLMHookService.shared.configure(
                        provider: LocalLLMProvider(settings: app.settings)
                    )
                }
        }
    }
}
