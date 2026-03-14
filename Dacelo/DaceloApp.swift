// DaceloApp.swift
// Dacelo

import SwiftUI

@main
struct DaceloApp: App {
    @StateObject private var app = AppStore()

    init() {
            print(Bundle.main.url(forResource: "pw", withExtension: "svg", subdirectory: "Pieces/cburnett") ?? "NOT FOUND")
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
