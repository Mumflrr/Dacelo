// DaceloApp.swift
// Dacelo

import SwiftUI

@main
struct DaceloApp: App {
    @StateObject private var app = AppStore()

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
