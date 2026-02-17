// ContentView.swift
// LeelaChessApp

import SwiftUI
import Chess

struct ContentView: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner()
                    .environmentObject(app.network)

                BoardView()
                    .environmentObject(app.chessStore)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 8)

                AnalysisPanel()
                    .environmentObject(app.analysis)

                GameControls()
                    .environmentObject(app)
                    .padding()
            }
            .navigationTitle("Leela Chess")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView().environmentObject(app)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    @EnvironmentObject var network: NetworkService

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(network.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(network.isConnected
                 ? "Connected to \(network.serverHost)"
                 : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !network.isConnected {
                Button("Connect") { network.connect() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.secondarySystemBackground)
    }
}

// MARK: - Analysis Panel

struct AnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Engine Feedback", systemImage: "brain.head.profile")
                    .font(.subheadline.bold())
                Spacer()
                if analysis.isAnalysing {
                    ProgressView().controlSize(.mini)
                }
                if let cp = analysis.scoreCP {
                    EvalBadge(scoreCP: cp)
                }
            }

            Text(analysis.lastFeedback.isEmpty
                 ? "Make a move to get feedback."
                 : analysis.lastFeedback)
                .font(.body)
                .foregroundStyle(analysis.lastFeedback.isEmpty ? .secondary : .primary)
                .animation(.easeInOut, value: analysis.lastFeedback)
                .lineLimit(3)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.tertiarySystemBackground)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Eval Badge

struct EvalBadge: View {
    let scoreCP: Int
    var body: some View {
        let pawns = Double(scoreCP) / 100.0
        Text(String(format: "%+.2f", pawns))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(scoreCP > 0 ? Color.white : Color.black)
            )
            .foregroundStyle(scoreCP > 0 ? Color.black : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Game Controls

struct GameControls: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(GameMode.allCases) { mode in
                    Button(mode.rawValue) { app.newGame(mode: mode) }
                }
            } label: {
                Label(app.gameMode.rawValue, systemImage: "person.2")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                app.newGame()
            } label: {
                Label("New Game", systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        Form {
            Section("Server Connection") {
                LabeledContent("Tailscale Host / IP") {
                    TextField("e.g. my-pc or 100.x.x.x", text: $app.serverHost)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                LabeledContent("Port") {
                    TextField("8765", value: $app.serverPort, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Button(app.network.isConnected ? "Reconnect" : "Connect") {
                    app.connectToServer()
                }
            }

            Section("Engine Settings") {
                LabeledContent("Think Time") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(app.moveTimeMs) },
                            set: { app.moveTimeMs = Int($0) }
                        ), in: 500...10000, step: 500)
                        Text("\(app.moveTimeMs)ms")
                            .monospacedDigit()
                            .frame(width: 65, alignment: .trailing)
                    }
                }
                LabeledContent("Game Mode") {
                    Picker("", selection: $app.gameMode) {
                        ForEach(GameMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }

            if let error = app.network.lastError {
                Section("Last Error") {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Cross-platform background shorthands

extension ShapeStyle where Self == Color {
    static var secondarySystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var tertiarySystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
