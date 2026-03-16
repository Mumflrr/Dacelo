// ContentView.swift
// Dacelo
//
// AnalysisPanel, ModernEvalBadge, WDLBar, MobilityBar, MaterialBalanceView,
// ConfidenceBadge, DepthNodeFooter, LLMNarrativeView all live in
// AnalysisPanelViews.swift — do not duplicate them here.

import SwiftUI
import Chess

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var app:      AppStore
    @EnvironmentObject var game:     GameStore
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var settings: AppSettings

    // 1. Define your two sets of gradient stops for morphing
    private var defaultStops: [Gradient.Stop] {
        [
            .init(color: .black,                location: 0.00),
            .init(color: .blue.opacity(0.18),   location: 0.45),
            .init(color: .purple.opacity(0.22), location: 0.75),
            .init(color: .black.opacity(0.90),  location: 0.99)
        ]
    }

    private var analysisStops: [Gradient.Stop] {
        [
            .init(color: .black,                 location: 0.00),
            .init(color: .indigo.opacity(0.40),  location: 0.60),
            .init(color: .purple.opacity(0.45),  location: 0.85),
            .init(color: .black.opacity(0.95),   location: 1.00)
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 2. Use the computed stops and add the animation modifier
                LinearGradient(
                    stops: game.gameMode == .analysisOnly ? analysisStops : defaultStops,
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: game.gameMode)
                
                #if os(macOS)
                macOSLayout
                #else
                iOSLayout
                #endif
            }
            .navigationTitle(game.gameMode == .analysisOnly ? "Analysis" : "Dacelo")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ConnectionToolbarItem()
                        .environmentObject(app.engine.state)
                        .environmentObject(app)
                    
                    Button {
                        let next: GameMode = game.gameMode == .analysisOnly ? .humanVsEngine : .analysisOnly
                        // 3. Wrap the state change in withAnimation to smooth the icon transition
                        withAnimation(.easeInOut(duration: 0.8)) {
                            game.gameMode = next
                        }
                        app.newGame()
                    } label: {
                        Image(systemName: game.gameMode == .analysisOnly ? "chart.xyaxis.line" : "chart.xyaxis.line")
                            .foregroundStyle(game.gameMode == .analysisOnly ? .purple : .secondary)
                    }
                    
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

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    boardWithArrows
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .shadow(color: game.boardTheme.dark.opacity(0.45), radius: 28, y: 8)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
                        .fixedSize()
                }

                if let balance = analysis.materialBalance, balance != 0 {
                    MaterialBalanceView(balance: balance)
                        .padding(.horizontal, 16)
                }

                BoardControlBar()
                    .environmentObject(app)
                    .environmentObject(game)
                    .environmentObject(analysis)
                    .environmentObject(settings)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .padding(16)

            VStack(spacing: 0) {
                Group {
                    if game.gameMode == .analysisOnly {
                        ReviewAnalysisPanel()
                            .environmentObject(analysis)
                            .environmentObject(game)
                    } else {
                        AnalysisPanel()
                            .environmentObject(analysis)
                            .environmentObject(game)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                MoveNavigationBar()
                    .environmentObject(analysis)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Spacer()
            }
            .frame(width: 330)
            .padding(.trailing, 8)
            .overlay(alignment: .bottom) {
                MoveHistoryDrawer(
                    critiques:     analysis.moveCritiques,
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
                    boardWithArrows
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .shadow(color: game.boardTheme.dark.opacity(0.45), radius: 28, y: 8)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                        .layoutPriority(1)

                    if let balance = analysis.materialBalance, balance != 0 {
                        MaterialBalanceView(balance: balance)
                    }

                    BoardControlBar()
                        .environmentObject(app)
                        .environmentObject(game)
                        .environmentObject(analysis)
                        .environmentObject(settings)
                        .padding(.horizontal, 16)

                    Group {
                        if game.gameMode == .analysisOnly {
                            ReviewAnalysisPanel()
                                .environmentObject(analysis)
                                .environmentObject(game)
                        } else {
                            AnalysisPanel()
                                .environmentObject(analysis)
                                .environmentObject(game)
                        }
                    }
                    .padding(.horizontal, 16)

                    MoveNavigationBar()
                        .environmentObject(analysis)
                        .padding(.horizontal, 16)

                    Color.clear.frame(height: 80)
                }
            }
            MoveHistoryDrawer(
                critiques:     analysis.moveCritiques,
                selectedIndex: analysis.selectedCritiqueIndex
            )
        }
    }

    // MARK: - Board + arrows

    private var isFlipped: Bool {
        game.gameMode == .humanVsEngine && game.playerColor == .black
    }

    private var boardWithArrows: some View {
        ZStack {
            BoardLayout(boardTheme: game.boardTheme,
                            pieceSet:   settings.pieceSet,
                            isFlipped:  isFlipped)
                .environmentObject(game.chessStore)
                .environmentObject(game)
            BoardArrowOverlay(arrows: analysis.bestMoveArrow.map { [$0] } ?? [])
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(game.boardTheme.dark.opacity(0.35))
                .blur(radius: 20)
                .padding(-4)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(game.boardTheme.dark.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Board Control Bar

struct BoardControlBar: View {
    @EnvironmentObject var app:      AppStore
    @EnvironmentObject var game:     GameStore
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var settings: AppSettings

    private var engineDisplayName: String {
        settings.bestMoveEngine.isEmpty ? "Engine" : settings.bestMoveEngine.capitalized
    }

    private var pauseButtonLabel: String {
        game.isPaused ? "Resume \(engineDisplayName)" : "Take \(engineDisplayName)'s Turn"
    }

    var body: some View {
        HStack(spacing: 10) {
            if game.gameMode == .humanVsEngine {
                Button { game.togglePause() } label: {
                    Label(pauseButtonLabel, systemImage: game.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(game.isPaused ? .green : .orange)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(
                        (game.isPaused ? Color.green : Color.orange).opacity(0.15)
                    ))
                    .overlay(Capsule().strokeBorder(
                        (game.isPaused ? Color.green : Color.orange).opacity(0.4),
                        lineWidth: 1
                    ))
                }
                .buttonStyle(.plain)
            }

            if game.gameMode == .analysisOnly {
                Button { app.newGame() } label: {
                    Label("New Game", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(Color.purple.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Button { analysis.requestHint() } label: {
                HStack(spacing: 5) {
                    if analysis.isRequestingHint {
                        ProgressView().controlSize(.mini).tint(.blue)
                    } else {
                        Image(systemName: "lightbulb.fill")
                    }
                    Text("Hint").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.blue.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(analysis.isRequestingHint)

            Spacer()
        }
    }
}

// MARK: - Connection Toolbar Item

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

// MARK: - New Game Button

struct NewGameButton: View {
    @EnvironmentObject var app: AppStore
    var onNewGame: (() -> Void)? = nil

    var body: some View {
        Button {
            app.newGame()
            onNewGame?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                Text("New Game").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.blue, .purple],
                                         startPoint: .leading, endPoint: .trailing))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Move Navigation Bar

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

// MARK: - Shared background

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
            .frame(minWidth: 480, minHeight: 420)
            .preferredColorScheme(.dark)
        #else
        iOSSettings
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
        #endif
    }

    #if os(macOS)
    private var macOSSettings: some View {
        ZStack {
            appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    connectionCard
                    gameCard
                    boardCard
                    analysisCard
                    llmCard
                    engineCard
                }
                .padding(24)
            }
        }
    }

    private var connectionCard: some View {
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
                TextField("8765", value: $settings.serverPort, format: .number.grouping(.never))
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
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .foregroundStyle(.white)
                .font(.subheadline.weight(.semibold))

                if app.engine.state.isConnected {
                    Button("Refresh Engines") {
                        Task { await app.refreshAvailableEngines() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.subheadline)
                }
            }
        }
    }

    private var gameCard: some View {
        SettingsCard(title: "Game", icon: "gamecontroller.fill", iconColor: .purple) {
            SettingsRow(label: "Mode") {
                Picker("", selection: $game.gameMode) {
                    ForEach(GameMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            if game.gameMode == .humanVsEngine {
                Divider().background(.white.opacity(0.1))
                SettingsRow(label: "Play as") {
                    Picker("", selection: $game.playerColor) {
                        ForEach(PlayerColor.allCases) { color in Text(color.rawValue).tag(color) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 160)
                }
            }
            Divider().background(.white.opacity(0.1))
            NewGameButton(onNewGame: { dismiss() }).environmentObject(app)
        }
    }

    private var boardCard: some View {
        SettingsCard(title: "Board", icon: "squareshape.split.2x2", iconColor: .brown) {
            SettingsRow(label: "Theme") {
                HStack(spacing: 8) {
                    ForEach(BoardTheme.allCases) { theme in
                        BoardThemeSwatch(theme: theme, isSelected: game.boardTheme == theme)
                            .onTapGesture { game.setBoardTheme(theme) }
                    }
                }
            }
            Divider().background(.white.opacity(0.1))
            SettingsRow(label: "Pieces") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PieceSet.allCases) { set in
                            PieceSetSwatch(pieceSet: set,
                                           isSelected: settings.pieceSet == set)
                                .onTapGesture { settings.pieceSetName = set.rawValue }
                        }
                    }
                    .padding(.vertical, 2)
                    // Add padding INSIDE the scroll view to prevent the shadow/edge from clipping
                    .padding(.horizontal, 4)
                }
                // Increase this padding to push it further away from the "Pieces" text
                .padding(.leading, 16)
            }
        }
    }

    private var analysisCard: some View {
        SettingsCard(title: "Analysis", icon: "brain.head.profile", iconColor: .blue) {
            SettingsRow(label: "Show best-move arrow") {
                Toggle("", isOn: $settings.showBestMoveArrow).labelsHidden()
            }

            Divider().background(.white.opacity(0.1))

            SettingsRow(label: "Hint arrows") {
                Picker("", selection: $settings.hintCount) {
                    Text("1 (Best)").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented).frame(maxWidth: 180)
            }

            Divider().background(.white.opacity(0.1))

            SettingsRow(label: "Eval engine") {
                enginePicker($settings.evalEngine, placeholder: "stockfish")
            }

            Divider().background(.white.opacity(0.1))

            SettingsRow(label: "NNUE engine (analysis)") {
                enginePicker($settings.nnueEngine, placeholder: "stockfish")
            }

            Text("NNUE only runs in Analysis Mode. Must be Stockfish or compatible.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var llmCard: some View {
        SettingsCard(title: "AI Commentary", icon: "text.bubble.fill", iconColor: .purple) {
            SettingsRow(label: "Endpoint") {
                TextField("http://localhost:11434", text: $settings.llmEndpoint)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                    .frame(maxWidth: 220).autocorrectionDisabled()
            }
            Divider().background(.white.opacity(0.1))
            SettingsRow(label: "Model") {
                TextField("llama3", text: $settings.llmModel)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                    .frame(maxWidth: 160).autocorrectionDisabled()
            }
            Divider().background(.white.opacity(0.1))
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(LLMHookService.shared.isAvailable ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(LLMHookService.shared.isAvailable
                         ? "Connected · \(LLMHookService.shared.providerName)"
                         : "Not connected")
                        .font(.caption)
                        .foregroundStyle(LLMHookService.shared.isAvailable ? .green : .red)
                }
                Spacer()
                Button("Apply & Test") {
                    LLMHookService.shared.configure(
                        provider: LocalLLMProvider(settings: settings)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.purple.opacity(0.3)))
                .foregroundStyle(.white)
                .font(.subheadline.weight(.semibold))
            }
            Text("AI commentary appears in Analysis Mode only.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var engineCard: some View {
        SettingsCard(title: "Engine", icon: "cpu", iconColor: .green) {
            SettingsRow(label: "Move engine") {
                enginePicker($settings.bestMoveEngine, placeholder: "lc0")
            }

            Divider().background(.white.opacity(0.1))

            SettingsRow(label: "Move think time") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { Double(settings.moveTimeMs) },
                        set: { settings.moveTimeMs = Int($0) }
                    ), in: 500...10000, step: 500)
                    .frame(maxWidth: 180).accentColor(.green)
                    Text(settings.moveTimeMs >= 1000
                         ? "\(settings.moveTimeMs / 1000)s"
                         : "\(settings.moveTimeMs)ms")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Divider().background(.white.opacity(0.1))

            SettingsRow(label: "Eval think time") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { Double(settings.evalTimeMs) },
                        set: { settings.evalTimeMs = Int($0) }
                    ), in: 500...10000, step: 500)
                    .frame(maxWidth: 180).accentColor(.blue)
                    Text(settings.evalTimeMs >= 1000
                         ? "\(settings.evalTimeMs / 1000)s"
                         : "\(settings.evalTimeMs)ms")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Text("Move engine plays your opponent. Eval engine analyses every position — use Stockfish for full NNUE breakdowns.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Engine picker: shows a dropdown when the server has reported available engines,
    /// falls back to a text field if the list is empty (e.g. not yet connected).
    @ViewBuilder
    private func enginePicker(_ binding: Binding<String>, placeholder: String) -> some View {
        if settings.availableEngines.isEmpty {
            // Not connected yet — free-text fallback
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                .frame(maxWidth: 160)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            Picker("", selection: binding) {
                ForEach(settings.availableEngines, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
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
                        .multilineTextAlignment(.trailing).autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                }
                LabeledContent("Port") {
                    TextField("8765", value: $settings.serverPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Button(app.engine.state.isConnected ? "Reconnect" : "Connect") {
                    app.connectToServer()
                }.buttonStyle(.borderedProminent)

                if app.engine.state.isConnected {
                    Button("Refresh Engine List") {
                        Task { await app.refreshAvailableEngines() }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Section("Game") {
                Picker("Mode", selection: $game.gameMode) {
                    ForEach(GameMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                if game.gameMode == .humanVsEngine {
                    Picker("Play as", selection: $game.playerColor) {
                        ForEach(PlayerColor.allCases) { color in Text(color.rawValue).tag(color) }
                    }.pickerStyle(.segmented)
                }
                NewGameButton(onNewGame: { dismiss() }).environmentObject(app)
            }
            Section("Board") {
                LabeledContent("Theme") {
                    HStack(spacing: 6) {
                        ForEach(BoardTheme.allCases) { theme in
                            BoardThemeSwatch(theme: theme, isSelected: game.boardTheme == theme)
                                .onTapGesture { game.setBoardTheme(theme) }
                        }
                    }
                }
                LabeledContent("Pieces") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PieceSet.allCases) { set in
                                PieceSetSwatch(pieceSet: set,
                                               isSelected: settings.pieceSet == set)
                                    .onTapGesture { settings.pieceSetName = set.rawValue }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .padding(.leading, 4)
                }
            }
            Section("Analysis") {
                Toggle("Show best-move arrow", isOn: $settings.showBestMoveArrow)

                LabeledContent("Hint arrows") {
                    Picker("", selection: $settings.hintCount) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }

                LabeledContent("Eval engine") {
                    enginePicker($settings.evalEngine, placeholder: "stockfish")
                }

                LabeledContent("NNUE engine") {
                    enginePicker($settings.nnueEngine, placeholder: "stockfish")
                }
            }
            Section("AI Commentary") {
                LabeledContent("Endpoint") {
                    TextField("http://localhost:11434", text: $settings.llmEndpoint)
                        .multilineTextAlignment(.trailing).autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                }
                LabeledContent("Model") {
                    TextField("llama3", text: $settings.llmModel)
                        .multilineTextAlignment(.trailing).autocorrectionDisabled()
                }
                Button("Apply & Test") {
                    // 5. FIX: Same lowercase fix for the iOS settings menu
                    LLMHookService.shared.configure(
                        provider: LocalLLMProvider(settings: settings)
                    )
                }
            }
            Section("Engine") {
                LabeledContent("Move engine") {
                    enginePicker($settings.bestMoveEngine, placeholder: "lc0")
                }

                LabeledContent("Move think time") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.moveTimeMs) },
                            set: { settings.moveTimeMs = Int($0) }
                        ), in: 500...10000, step: 500)
                        Text("\(settings.moveTimeMs / 1000)s")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Eval think time") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(settings.evalTimeMs) },
                            set: { settings.evalTimeMs = Int($0) }
                        ), in: 500...10000, step: 500)
                        Text("\(settings.evalTimeMs / 1000)s")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
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

// MARK: - Board Theme Swatch

struct BoardThemeSwatch: View {
    let theme: BoardTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            theme.dark.frame(width: 22, height: 22)
            theme.light.frame(width: 22, height: 22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? .white.opacity(0.3) : .clear, radius: 4)
        .scaleEffect(isSelected ? 1.12 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
        .help(theme.rawValue)
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
        HStack(alignment: .center) {
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
                .font(.subheadline)
                .fixedSize()
            Spacer(minLength: 12)
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
