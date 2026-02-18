// ContentView.swift
// Dacelo
//
// Modern main interface with glassmorphism and animations

import SwiftUI
import Chess

struct ContentView: View {
    @EnvironmentObject var app: AppStore
    @State private var showingMoveHistory = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color.blue.opacity(0.15),
                        Color.purple.opacity(0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ConnectionBanner()
                        .environmentObject(app.network)

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
                    Button {
                        showingMoveHistory = true
                    } label: {
                        Image(systemName: "list.bullet.clipboard.fill")
                            .foregroundStyle(.white)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    NavigationLink {
                        MoveHistoryView(critiques: app.analysis.moveCritiques)
                            .environmentObject(app)
                    } label: {
                        Image(systemName: "list.bullet.clipboard.fill")
                    }
                }
                #endif

                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SettingsView().environmentObject(app)
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
                    MoveHistoryView(critiques: app.analysis.moveCritiques)
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

    // MARK: - macOS: board left, controls right

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // Board — fills available height, square aspect ratio
            BoardView()
                .environmentObject(app.chessStore)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

            // Right panel — fixed width
            VStack(spacing: 14) {
                AnalysisPanel()
                    .environmentObject(app.analysis)

                NewGameButton()
                    .environmentObject(app)

                Spacer()
            }
            .frame(width: 300)
            .padding(.top, 16)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    // MARK: - iOS: vertical scroll

    private var iOSLayout: some View {
        ScrollView {
            VStack(spacing: 16) {
                BoardView()
                    .environmentObject(app.chessStore)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                AnalysisPanel()
                    .environmentObject(app.analysis)
                    .padding(.horizontal, 16)

                NewGameButton()
                    .environmentObject(app)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    @EnvironmentObject var network: NetworkService

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(network.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)

                if network.isConnected {
                    Circle()
                        .stroke(Color.green.opacity(0.5), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .opacity(0)
                        .animation(
                            .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                            value: network.isConnected
                        )
                }
            }

            Text(network.isConnected
                 ? "Connected to \(network.serverHost)"
                 : "Not connected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            if !network.isConnected {
                Button {
                    network.connect()
                } label: {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.blue.gradient))
                }
                .buttonStyle(.plain)   // no grey box
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle().fill(
                        LinearGradient(
                            colors: [network.isConnected ? .green.opacity(0.2) : .red.opacity(0.2), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
        )
    }
}

// MARK: - Analysis Panel

struct AnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisService
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row — always visible
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.blue.gradient.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: "brain.head.profile")
                        .font(.title3)
                        .foregroundStyle(.blue.gradient)
                        .rotationEffect(.degrees(analysis.isAnalysing ? 360 : 0))
                        .animation(
                            analysis.isAnalysing
                                ? .linear(duration: 2).repeatForever(autoreverses: false)
                                : .default,
                            value: analysis.isAnalysing
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine Analysis")
                        .font(.headline)
                        .foregroundStyle(.white)

                    if analysis.isAnalysing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.blue)
                            Text("Analysing…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Spacer()

                if let cp = analysis.scoreCP {
                    ModernEvalBadge(scoreCP: cp)
                }

                // Expand / collapse toggle — always shown
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Collapsible body
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(analysis.lastFeedback.isEmpty
                         ? "Make a move to get engine feedback."
                         : analysis.lastFeedback)
                        .font(.subheadline)
                        .foregroundStyle(analysis.lastFeedback.isEmpty
                                         ? .white.opacity(0.5)
                                         : .white.opacity(0.9))
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
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Eval Badge

struct ModernEvalBadge: View {
    let scoreCP: Int

    var body: some View {
        let pawns = Double(scoreCP) / 100.0
        VStack(spacing: 2) {
            Text(String(format: "%+.2f", pawns))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .fixedSize()                    // never wrap the number
            Text("pawns")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 70)                    // wide enough for "-10.00"
        .background(RoundedRectangle(cornerRadius: 10).fill(evalGradient))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    private var evalGradient: LinearGradient {
        if scoreCP > 0 {
            return LinearGradient(colors: [.green.opacity(0.8), .green.opacity(0.5)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        } else if scoreCP < 0 {
            return LinearGradient(colors: [.red.opacity(0.8), .red.opacity(0.5)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            return LinearGradient(colors: [.gray.opacity(0.6), .gray.opacity(0.4)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - New Game Button (game mode dropdown moved to Settings)

struct NewGameButton: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        Button {
            app.newGame()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                Text("New Game")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
        .buttonStyle(.plain)   // no grey box on macOS
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var app: AppStore
    @Environment(\.dismiss) private var dismiss

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

    // MARK: macOS — custom card-based layout

    #if os(macOS)
    private var macOSSettings: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color.blue.opacity(0.12), Color.purple.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {

                    // — Server —
                    SettingsCard(title: "Server Connection", icon: "network", iconColor: .blue) {
                        SettingsRow(label: "Tailscale Host / IP") {
                            TextField("e.g. my-pc or 100.x.x.x", text: $app.serverHost)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                                .frame(maxWidth: 220)
                                .autocorrectionDisabled()
                        }

                        Divider().background(.white.opacity(0.1))

                        SettingsRow(label: "Port") {
                            TextField("8765", value: $app.serverPort, format: .number.grouping(.never))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                                .frame(width: 90)
                        }

                        Divider().background(.white.opacity(0.1))

                        HStack {
                            if app.network.isConnected {
                                Label("Connected to \(app.serverHost)", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if let err = app.network.lastError {
                                Label(err, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            } else {
                                Spacer()
                            }
                            Spacer()
                            Button(app.network.isConnected ? "Reconnect" : "Connect") {
                                app.connectToServer()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(LinearGradient(colors: [.blue, .blue.opacity(0.7)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            )
                            .foregroundStyle(.white)
                            .font(.subheadline.weight(.semibold))
                        }
                    }

                    // — Game Mode —
                    SettingsCard(title: "Game Mode", icon: "person.2.fill", iconColor: .purple) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(GameMode.allCases) { mode in
                                Button {
                                    app.gameMode = mode
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: app.gameMode == mode
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(app.gameMode == mode ? .blue : .white.opacity(0.4))
                                            .font(.body)

                                        Text(mode.rawValue)
                                            .foregroundStyle(.white.opacity(0.9))
                                            .font(.subheadline)

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

                    // — Engine —
                    SettingsCard(title: "Engine", icon: "cpu", iconColor: .green) {
                        SettingsRow(label: "Think Time") {
                            HStack(spacing: 10) {
                                Slider(value: Binding(
                                    get: { Double(app.moveTimeMs) },
                                    set: { app.moveTimeMs = Int($0) }
                                ), in: 500...10000, step: 500)
                                .frame(maxWidth: 180)
                                .accentColor(.blue)

                                Text(app.moveTimeMs >= 1000
                                     ? "\(app.moveTimeMs / 1000)s"
                                     : "\(app.moveTimeMs)ms")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 44, alignment: .trailing)                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
    #endif

    // MARK: iOS — standard Form

    private var iOSSettings: some View {
        Form {
            Section("Server Connection") {
                LabeledContent("Host / IP") {
                    TextField("e.g. my-pc or 100.x.x.x", text: $app.serverHost)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                LabeledContent("Port") {
                    TextField("8765", value: $app.serverPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                Button(app.network.isConnected ? "Reconnect" : "Connect") {
                    app.connectToServer()
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Game Mode") {
                Picker("Play as", selection: $app.gameMode) {
                    ForEach(GameMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section("Engine") {
                LabeledContent("Think Time") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(app.moveTimeMs) },
                            set: { app.moveTimeMs = Int($0) }
                        ), in: 500...10000, step: 500)
                        Text("\(app.moveTimeMs)ms")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }

            if let error = app.network.lastError {
                Section("Last Error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Settings Card (macOS)

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
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            content
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Settings Row (macOS)

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
                .font(.subheadline)
            Spacer()
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
