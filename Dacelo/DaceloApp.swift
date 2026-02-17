// LeelaChessApp.swift
// LeelaChessApp

import SwiftUI

@main
struct DaceloApp: App {
    @StateObject private var appStore = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appStore)
                .onAppear {
                    appStore.connectToServer()
                }
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}
