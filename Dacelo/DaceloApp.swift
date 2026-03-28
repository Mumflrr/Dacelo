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
                .environmentObject(app.engineState)
                .onAppear {
                    LLMHookService.shared.configure(
                        provider: LocalLLMProvider(settings: app.settings)
                    )
                }
        }
        #if os(macOS)
        .commands {
            // ── Game ─────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("New Game") {
                    app.newGame()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Game") {
                //Button(app.gameStore.isPaused ? "Resume Engine" : "Pause Engine") {
                //    app.gameStore.togglePause()
                //}
                //.keyboardShortcut(.space, modifiers: [])
                //.disabled(app.gameStore.gameMode != .humanVsEngine)

                //Divider()

                Button(app.gameStore.gameMode == .analysisOnly ? "Exit Analysis" : "Enter Analysis") {
                    if app.gameStore.gameMode == .analysisOnly {
                        app.exitAnalysisMode()
                    } else {
                        app.enterAnalysisMode()
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // ── Navigation ────────────────────────────────────────
            CommandMenu("Navigate") {
                Button("Previous Move") {
                    app.analysis.goBack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Next Move") {
                    app.analysis.goForward()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Divider()

                Button("Show Hint") {
                    app.analysis.requestHint(count: app.settings.hintCount)
                }
                .keyboardShortcut("h", modifiers: .command)
                .disabled(app.analysis.isRequestingHint)
            }
        }
        #endif
    }
}
