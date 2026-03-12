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

    var body: some View {
        NavigationStack {
            ZStack {
                // Force pure dark background — not material, not mode-dependent
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [.black, .blue.opacity(0.15), .purple.opacity(0.1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                #if os(macOS)
                macOSLayout
                #else
                iOSLayout
                #endif
            }
            .navigationTitle("Leela Chess")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .preferredColorScheme(.dark)
            .toolbar {
                // Leading area is just the title on macOS.
                // Trailing: connection dot+label then settings gear, left to right.
                ToolbarItemGroup(placement: .primaryAction) {
                    ConnectionToolbarItem()
                        .environmentObject(app.engine.state)
                        .environmentObject(app)
                    NavigationLink {
                        SettingsView()
                            .environmentObject(app)
                            .environmentObject(settings)
                            .environmentObject(game)
                    } label: {
                        Image(systemName: "gearshape.fill")
                        #if os(iOS)
                            .foregroundStyle(.white)
                        #endif
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 640)
        #endif
    }

    // MARK: - macOS layout
    // Board left, sidebar right.
    // Sidebar: AnalysisPanel + nav arrows at top, history drawer pinned to bottom.

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── Board ─────────────────────────────────────────────────────
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                BoardView()
                    .environmentObject(game.chessStore)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            }
            .padding(16)

            // ── Sidebar ───────────────────────────────────────────────────
            VStack(spacing: 0) {
                // Analysis panel + PV line
                AnalysisPanel()
                    .environmentObject(analysis)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                // Move navigation arrows
                MoveNavigationBar()
                    .environmentObject(analysis)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                Spacer()
            }
            .frame(width: 330)
            .padding(.trailing, 8)
            // Drawer overlaid at bottom — floats over spacer and nav bar when expanded
            .overlay(alignment: .bottom) {
                MoveHistoryDrawer(
                    critiques: analysis.moveCritiques,
                    selectedIndex: analysis.selectedCritiqueIndex
                )
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    // MARK: - iOS layout

    private var iOSLayout: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 14) {
                    BoardView()
                        .environmentObject(game.chessStore)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                    AnalysisPanel()
                        .environmentObject(analysis)
                        .padding(.horizontal, 16)

                    MoveNavigationBar()
                        .environmentObject(analysis)
                        .padding(.horizontal, 16)

                    // Space so content isn't hidden behind drawer
                    Color.clear.frame(height: 80)
                }
            }

            MoveHistoryDrawer(
                critiques: analysis.moveCritiques,
                selectedIndex: analysis.selectedCritiqueIndex
            )
        }
    }
}

// MARK: - Connection Toolbar Item
// Plain dot + hostname/Connect text. No background — sits naturally in the toolbar
// to the left of the settings gear icon.

struct ConnectionToolbarItem: View {
    @EnvironmentObject var connectionState: EngineConnectionState
    @EnvironmentObject var app: AppStore

    var body: some View {
        Button { if !connectionState.isConnected { app.connectToServer() } } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionState.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(connectionState.isConnected
                     ? app.settings.serverHost
                     : "Connect")
                    .font(.caption.weight(connectionState.isConnected ? .regular : .semibold))
            }
            .foregroundStyle(connectionState.isConnected ? Color.secondary : Color.red)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .disabled(connectionState.isConnected)
    }
}

// MARK: - Analysis Panel
// Copied verbatim from original, with EngineLineView for best-line PV added.

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

                    // Best line PV
                    if !analysis.currentPV.isEmpty {
                        EngineLineView(label: "Best line",
                                       moves: analysis.currentPV,
                                       accentColor: .blue)
                    }

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

// MARK: - New Game Button (used inside Settings only)

struct NewGameButton: View {
    @EnvironmentObject var app: AppStore
    var onNewGame: (() -> Void)? = nil

    var body: some View {
        Button {
            app.newGame()
            onNewGame?()
        } label: {
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

// MARK: - Move Navigation Bar
// Prev/next arrows to step through move history cards.

struct MoveNavigationBar: View {
    @EnvironmentObject var analysis: AnalysisStore

    private var positionLabel: String {
        guard !analysis.moveCritiques.isEmpty else { return "No moves yet" }
        guard let idx = analysis.selectedCritiqueIndex else { return "Latest" }
        let c = analysis.moveCritiques[idx]
        let uciStr: String = {
            let m = c.move
            guard m.count >= 4 else { return c.moveNotation }
            return "\(m.prefix(2))→\(m.dropFirst(2).prefix(2))"
        }()
        return "\(c.moveNotation) \(uciStr)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) { analysis.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(analysis.canGoBack ? 0.12 : 0.05)))
                    .foregroundStyle(.white.opacity(analysis.canGoBack ? 0.9 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(!analysis.canGoBack)

            Spacer()

            Text(positionLabel)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) { analysis.goForward() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(analysis.canGoForward ? 0.12 : 0.05)))
                    .foregroundStyle(.white.opacity(analysis.canGoForward ? 0.9 : 0.3))
            }
            .buttonStyle(.plain)
            .disabled(!analysis.canGoForward)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
}

// MARK: - Rounded top corners shape

struct RoundedCornersShape: InsettableShape {
    var tl: CGFloat = 0, tr: CGFloat = 0, bl: CGFloat = 0, br: CGFloat = 0
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> RoundedCornersShape {
        var copy = self; copy.insetAmount = amount; return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        path.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr),
                    radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        path.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br),
                    radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        path.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl),
                    radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        path.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl),
                    radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Shared background (always dark — not color-scheme dependent)

var appBackground: some View {
    ZStack {
        Color.black
        LinearGradient(
            colors: [.blue.opacity(0.12), .purple.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var app:      AppStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var game:     GameStore
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
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(.white.opacity(0.08)))
                                .frame(maxWidth: 220).autocorrectionDisabled()
                        }
                        Divider().background(.white.opacity(0.1))
                        SettingsRow(label: "Port") {
                            TextField("8765", value: $settings.serverPort,
                                      format: .number.grouping(.never))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(.white.opacity(0.08)))
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

                    SettingsCard(title: "Game", icon: "gamecontroller.fill", iconColor: .purple) {
                        SettingsRow(label: "Game Mode") {
                            Picker("", selection: $game.gameMode) {
                                ForEach(GameMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Divider().background(.white.opacity(0.1))
                        NewGameButton(onNewGame: { dismiss() })
                            .environmentObject(app)
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
            Section("Game") {
                Picker("Play as", selection: $game.gameMode) {
                    ForEach(GameMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                NewGameButton(onNewGame: { dismiss() }).environmentObject(app)
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
