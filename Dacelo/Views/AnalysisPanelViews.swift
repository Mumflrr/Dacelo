// AnalysisPanelViews.swift
// Dacelo
//
// All analysis panel UI components:
//   AnalysisPanel        — main panel shown in both regular and analysis mode
//   WDLBar               — win/draw/loss probability bar
//   MobilityBar          — side-by-side mobility comparison
//   MaterialBalanceView  — captured piece differential row
//   ConfidenceBadge      — engine confidence capsule
//   DepthNodeFooter      — depth · nodes footer line
//   LLMNarrativeView     — analysis mode LLM text block
//   ModernEvalBadge      — kept from original, unchanged

import SwiftUI

// MARK: - Analysis Panel

struct AnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var game:     GameStore
    @State private var isExpanded = true

    private var isAnalysisMode: Bool { game.gameMode == .analysisOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ────────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 12) {
                brainIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(isAnalysisMode ? "Analysis Mode" : "Engine Analysis")
                        .font(.headline).foregroundStyle(.white)
                    if analysis.isAnalysing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).tint(.blue)
                            Text("Analysing…")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                Spacer()
                if let cp = analysis.scoreCP { ModernEvalBadge(scoreCP: cp) }
                expandButton
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {

                    // ── WDL bar ───────────────────────────────────────────
                    if let wdl = analysis.wdl {
                        WDLBar(wdl: wdl)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // ── Confidence + characteristics badges ───────────────
                    if let chars = analysis.currentCharacteristics {
                        characteristicsBadgeRow(chars)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // ── Feedback text ─────────────────────────────────────
                    Text(analysis.lastFeedback.isEmpty
                         ? "Make a move to get engine feedback."
                         : analysis.lastFeedback)
                        .font(.subheadline)
                        .foregroundStyle(analysis.lastFeedback.isEmpty
                                         ? .white.opacity(0.5) : .white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut, value: analysis.lastFeedback)

                    // ── Best line ─────────────────────────────────────────
                    if !analysis.currentPV.isEmpty {
                        EngineLineView(label: "Best line",
                                       moves: analysis.currentPV,
                                       accentColor: .blue)
                    }

                    // ── Mobility bar ──────────────────────────────────────
                    if let mw = analysis.mobilityWhite,
                       let mb = analysis.mobilityBlack,
                       mw + mb > 0 {
                        MobilityBar(white: mw, black: mb)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // ── Depth · nodes footer ──────────────────────────────
                    if let d = analysis.depth, let n = analysis.nodes {
                        DepthNodeFooter(depth: d, nodes: n)
                    }

                    // ── LLM narrative (analysis mode only) ────────────────
                    if isAnalysisMode {
                        LLMNarrativeView()
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
                    LinearGradient(
                        colors: isAnalysisMode
                            ? [.purple.opacity(0.5), .blue.opacity(0.3)]
                            : [.blue.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isAnalysisMode ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isAnalysisMode)
    }

    // ── Characteristic badge row ──────────────────────────────────────────────
    @ViewBuilder
    private func characteristicsBadgeRow(_ chars: PositionCharacteristics) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ConfidenceBadge(confidence: chars.confidence)
                CharBadge(text: chars.sharpness,  icon: sharpnessIcon(chars.sharpness),  color: sharpnessColor(chars.sharpness))
                CharBadge(text: chars.difficulty, icon: difficultyIcon(chars.difficulty), color: difficultyColor(chars.difficulty))
                CharBadge(text: chars.line_type,  icon: lineTypeIcon(chars.line_type),   color: .purple)
            }
            .padding(.vertical, 2)
        }
    }

    // ── Icons / colours ───────────────────────────────────────────────────────

    private func sharpnessIcon(_ s: String) -> String {
        switch s {
        case "Sharp":    return "flame.fill"
        case "Tactical": return "bolt.fill"
        case "Balanced": return "scalemass.fill"
        default:         return "leaf.fill"
        }
    }
    private func sharpnessColor(_ s: String) -> Color {
        switch s {
        case "Sharp":    return .red
        case "Tactical": return .orange
        case "Balanced": return .blue
        default:         return .green
        }
    }
    private func difficultyIcon(_ d: String) -> String {
        switch d {
        case "Expert":       return "star.circle.fill"
        case "Advanced":     return "3.circle.fill"
        case "Intermediate": return "2.circle.fill"
        default:             return "1.circle.fill"
        }
    }
    private func difficultyColor(_ d: String) -> Color {
        switch d {
        case "Expert":       return .red
        case "Advanced":     return .orange
        case "Intermediate": return .yellow
        default:             return .green
        }
    }
    private func lineTypeIcon(_ l: String) -> String {
        switch l {
        case "Forcing":   return "bolt.circle.fill"
        case "Tactical":  return "scope"
        case "Committal": return "arrow.right.circle.fill"
        case "Flexible":  return "arrow.triangle.branch"
        default:          return "tortoise.fill"
        }
    }

    // ── Brain icon ────────────────────────────────────────────────────────────
    private var brainIcon: some View {
        ZStack {
            Circle()
                .fill((isAnalysisMode ? Color.purple : Color.blue).gradient.opacity(0.2))
                .frame(width: 40, height: 40)
            Image(systemName: isAnalysisMode ? "chart.xyaxis.line" : "brain.head.profile")
                .font(.title3)
                .foregroundStyle((isAnalysisMode ? Color.purple : Color.blue).gradient)
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

// MARK: - WDL Bar

struct WDLBar: View {
    let wdl: WDLResponse

    private var whitePercent: Int { Int((wdl.white * 100).rounded()) }
    private var drawPercent:  Int { Int((wdl.draw  * 100).rounded()) }
    private var blackPercent: Int { Int((wdl.black * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: geo.size.width * wdl.white)
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.white.opacity(0.3))
                        .frame(width: geo.size.width * wdl.draw)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.85))
                        .frame(width: max(0, geo.size.width * wdl.black - 2))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
            }
            .frame(height: 10)

            // Labels
            HStack {
                Text("W \(whitePercent)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("D \(drawPercent)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("B \(blackPercent)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: wdl.white)
    }
}

// MARK: - Mobility Bar

struct MobilityBar: View {
    let white: Int
    let black: Int

    private var total: Double { Double(white + black) }
    private var whiteFrac: Double { total > 0 ? Double(white) / total : 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Mobility")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("W\(white) · B\(black)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            GeometryReader { geo in
                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: geo.size.width * whiteFrac)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: max(0, geo.size.width * (1 - whiteFrac) - 1))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
            }
            .frame(height: 7)
        }
        .animation(.easeInOut(duration: 0.4), value: white)
    }
}

// MARK: - Material Balance View
// Shown below the board between board and control bar.
// Hidden when material is equal.

struct MaterialBalanceView: View {
    let balance: Int  // white-positive, pawn units

    var body: some View {
        if balance == 0 { EmptyView() } else { row }
    }

    private var row: some View {
        HStack(spacing: 6) {
            if balance > 0 {
                Text("♙ ×\(balance)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("+\(balance)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            } else {
                Text("♟ ×\(abs(balance))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(balance)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .animation(.spring(response: 0.3), value: balance)
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let confidence: String

    private var color: Color {
        switch confidence {
        case "Confident": return .green
        case "Uncertain": return .yellow
        default:          return .red
        }
    }

    private var icon: String {
        switch confidence {
        case "Confident": return "checkmark.seal.fill"
        case "Uncertain": return "questionmark.circle.fill"
        default:          return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        CharBadge(text: confidence, icon: icon, color: color)
    }
}

// MARK: - Char Badge (shared capsule badge)

struct CharBadge: View {
    let text:  String
    let icon:  String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .foregroundStyle(color)
    }
}

// MARK: - Depth / Node Footer

struct DepthNodeFooter: View {
    let depth: Int
    let nodes: Int

    private var nodesFormatted: String {
        if nodes >= 1_000_000 {
            return String(format: "%.1fM nodes", Double(nodes) / 1_000_000)
        } else if nodes >= 1_000 {
            return String(format: "%.1fk nodes", Double(nodes) / 1_000)
        } else {
            return "\(nodes) nodes"
        }
    }

    var body: some View {
        Text("depth \(depth) · \(nodesFormatted)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - LLM Narrative View

struct LLMNarrativeView: View {
    @ObservedObject private var llm = LLMHookService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                Text("AI Commentary")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                if llm.isAnalysing {
                    ProgressView().controlSize(.mini).tint(.purple)
                } else if !llm.isAvailable {
                    Text("LLM offline")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            if llm.isAnalysing {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.purple.opacity(0.6))
                            .frame(width: 6, height: 6)
                            .scaleEffect(llm.isAnalysing ? 1.0 : 0.5)
                            .animation(
                                .easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                value: llm.isAnalysing
                            )
                    }
                }
                .padding(.vertical, 4)
            } else if !llm.lastNarrative.isEmpty {
                Text(llm.lastNarrative)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: llm.lastNarrative)
            } else if llm.isAvailable {
                Text("Make a move for AI commentary.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Eval Badge (kept from original)

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
