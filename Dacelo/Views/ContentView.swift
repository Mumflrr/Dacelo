// ContentView.swift
// Dacelo

import SwiftUI
import Chess

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var app:      AppStore
    @EnvironmentObject var game:     GameStore
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var settings: AppSettings
    @State private var showingMoveHistory = false

    var body: some View {
        NavigationStack {
            ZStack {
                appBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    ConnectionBanner()
                        .environmentObject(app.engine.state)
                        .environmentObject(app)
                    #if os(macOS)
                    macOSLayout
                    #else
                    iOSLayout
                    #endif
                }
            }
            .navigationTitle("Leela Chess")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingMoveHistory = true } label: {
                        Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(.white)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    NavigationLink {
                        MoveHistoryView(critiques: analysis.moveCritiques)
                    } label: {
                        Image(systemName: "list.bullet.clipboard.fill")
                    }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView()
                            .environmentObject(app)
                            .environmentObject(settings)
                    } label: {
                        Image(systemName: "gearshape.fill")
                        #if os(iOS)
                            .foregroundStyle(.white)
                        #endif
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingMoveHistory) {
                NavigationStack {
                    MoveHistoryView(critiques: analysis.moveCritiques)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingMoveHistory = false }
                            }
                        }
                }
            }
            #endif
        }
    }

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            BoardView()
                .environmentObject(game.chessStore)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            VStack(spacing: 14) {
                AnalysisPanel().environmentObject(analysis)
                NewGameButton().environmentObject(app)
                Spacer()
            }
            .frame(width: 300)
            .padding([.top, .trailing, .bottom], 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private var iOSLayout: some View {
        ScrollView {
            VStack(spacing: 16) {
                BoardView()
                    .environmentObject(game.chessStore)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                AnalysisPanel().environmentObject(analysis)
                    .padding(.horizontal, 16)
                NewGameButton().environmentObject(app)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Shared background

var appBackground: some View {
    LinearGradient(
        colors: [.black, .blue.opacity(0.15), .purple.opacity(0.1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    @EnvironmentObject var connectionState: EngineConnectionState
    @EnvironmentObject var app: AppStore

    var body: some View {
        HStack(spacing: 10) {
            connectionDot
            Text(connectionState.isConnected
                 ? "Connected to \(app.settings.serverHost)"
                 : "Not connected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            if !connectionState.isConnected {
                Button { app.connectToServer() } label: {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.blue.gradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(
                    LinearGradient(
                        colors: [connectionState.isConnected ? .green.opacity(0.2) : .red.opacity(0.2), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                ))
        )
    }

    private var connectionDot: some View {
        ZStack {
            Circle()
                .fill(connectionState.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            if connectionState.isConnected {
                Circle()
                    .stroke(Color.green.opacity(0.5), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .opacity(0)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false),
                               value: connectionState.isConnected)
            }
        }
    }
}

// MARK: - Analysis Panel

struct AnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisStore
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                brainIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine Analysis").font(.headline).foregroundStyle(.white)
                    if analysis.isAnalysing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).tint(.blue)
                            Text("Analysing…").font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                Spacer()
                if let cp = analysis.scoreCP { ModernEvalBadge(scoreCP: cp) }
                expandButton
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(analysis.lastFeedback.isEmpty
                         ? "Make a move to get engine feedback."
                         : analysis.lastFeedback)
                        .font(.subheadline)
                        .foregroundStyle(analysis.lastFeedback.isEmpty
                                         ? .white.opacity(0.5) : .white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut, value: analysis.lastFeedback)
                    if let chars = analysis.currentCharacteristics {
                        CharacteristicsBadges(characteristics: chars)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
    }

    private var brainIcon: some View {
        ZStack {
            Circle().fill(.blue.gradient.opacity(0.2)).frame(width: 40, height: 40)
            Image(systemName: "brain.head.profile")
                .font(.title3).foregroundStyle(.blue.gradient)
                .rotationEffect(.degrees(analysis.isAnalysing ? 360 : 0))
                .animation(
                    analysis.isAnalysing
                        ? .linear(duration: 2).repeatForever(autoreverses: false)
                        : .default,
                    value: analysis.isAnalysing
                )
        }
    }

    private var expandButton: some View {
        Button {
            withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Eval Badge

struct ModernEvalBadge: View {
    let scoreCP: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%+.2f", Double(scoreCP) / 100.0))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white).fixedSize()
            Text("pawns")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 70)
        .background(RoundedRectangle(cornerRadius: 10).fill(evalGradient))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    private var evalGradient: LinearGradient {
        let color: Color = scoreCP > 0 ? .green : scoreCP < 0 ? .red : .gray
        return LinearGradient(colors: [color.opacity(0.8), color.opacity(0.5)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - New Game Button

struct NewGameButton: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        Button { app.newGame() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                Text("New Game").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .leading, endPoint: .trailing))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var app:      AppStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var game:     GameStore

    var body: some View {
        #if os(macOS)
        macOSSettings
            .navigationTitle("Settings")
            .frame(minWidth: 460, minHeight: 400)
        #else
        iOSSettings
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
    private var macOSSettings: some View {
        ZStack {
            appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    SettingsCard(title: "Server Connection", icon: "network", iconColor: .blue) {
                        SettingsRow(label: "Tailscale Host / IP") {
                            TextField("e.g. my-pc or 100.x.x.x", text: $settings.serverHost)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                                .frame(maxWidth: 220).autocorrectionDisabled()
                        }
                        Divider().background(.white.opacity(0.1))
                        SettingsRow(label: "Port") {
                            TextField("8765", value: $settings.serverPort,
                                      format: .number.grouping(.never))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                                .frame(width: 90)
                        }
                        Divider().background(.white.opacity(0.1))
                        HStack {
                            connectionStatus
                            Spacer()
                            Button(app.engine.state.isConnected ? "Reconnect" : "Connect") {
                                app.connectToServer()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(LinearGradient(colors: [.blue, .blue.opacity(0.7)],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                            )
                            .foregroundStyle(.white)
                            .font(.subheadline.weight(.semibold))
                        }
                    }

                    SettingsCard(title: "Game Mode", icon: "person.2.fill", iconColor: .purple) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(GameMode.allCases) { mode in
                                Button { game.gameMode = mode } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: game.gameMode == mode
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(game.gameMode == mode
                                                             ? .blue : .white.opacity(0.4))
                                        Text(mode.rawValue)
                                            .foregroundStyle(.white.opacity(0.9)).font(.subheadline)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if mode != GameMode.allCases.last {
                                    Divider().background(.white.opacity(0.08))
                                }
                            }
                        }
                    }

                    SettingsCard(title: "Engine", icon: "cpu", iconColor: .green) {
                        SettingsRow(label: "Think Time") {
                            HStack(spacing: 10) {
                                Slider(value: Binding(
                                    get: { Double(settings.moveTimeMs) },
                                    set: { settings.moveTimeMs = Int($0) }
                                ), in: 500...10000, step: 500)
                                .frame(maxWidth: 180).accentColor(.blue)
                                Text(settings.moveTimeMs >= 1000
                                     ? "\(settings.moveTimeMs / 1000)s"
                                     : "\(settings.moveTimeMs)ms")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if app.engine.state.isConnected {
            Label("Connected to \(settings.serverHost)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else if let err = app.engine.state.lastError {
            Label(err, systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
    #endif

    private var iOSSettings: some View {
        Form {
            Section("Server Connection") {
                LabeledContent("Host / IP") {
                    TextField("e.g. my-pc or 100.x.x.x", text: $settings.serverHost)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                LabeledContent("Port") {
                    TextField("8765", value: $settings.serverPort,
                              format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Button(app.engine.state.isConnected ? "Reconnect" : "Connect") {
                    app.connectToServer()
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Game Mode") {
                Picker("Play as", selection: $game.gameMode) {
                    ForEach(GameMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
            }
            Section("Engine") {
                LabeledContent("Think Time") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.moveTimeMs) },
                            set: { settings.moveTimeMs = Int($0) }
                        ), in: 500...10000, step: 500)
                        Text("\(settings.moveTimeMs)ms")
                            .monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
            }
            if let error = app.engine.state.lastError {
                Section("Last Error") {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }
}

// MARK: - Settings Card / Row (macOS)

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconColor.opacity(0.2)).frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(iconColor)
                }
                Text(title).font(.headline).foregroundStyle(.white)
            }
            content
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.7)).font(.subheadline)
            Spacer()
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
