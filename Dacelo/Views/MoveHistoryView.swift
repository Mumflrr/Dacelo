// MoveHistoryView.swift
// Dacelo
//
// Move history UI components used in the MoveHistoryDrawer.
//
//   MoveHistorySection    — collapsible list of MoveCards
//   MoveHistoryView       — full-screen standalone wrapper (NavigationStack)
//   MoveCard              — one card per move: piece icon, notation, quality badge,
//                           eval delta, engine line, characteristics badges,
//                           alternatives, and (when selected) LLM narrative
//   QualityBadge          — colour-coded move quality capsule
//   EvalChangeIndicator   — before/after centipawn delta arrow
//   CharacteristicsBadges — position_type, precision_required, eval_stability,
//                           line_type badges with explanation text
//   AlternativesSection   — collapsible MultiPV alternative lines
//   AlternativeLineRow    — ranked alternative with PV
//   EngineLineView        — scrollable UCI move sequence

import SwiftUI

// MARK: - Collapsible Move History Section

struct MoveHistorySection: View {
    let critiques: [MoveCritique]
    @State private var isExpanded: Bool = true
    @State private var selectedID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            Button {
                withAnimation(.spring(response: 0.35)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Move History")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(1)
                    Spacer()
                    Text("\(critiques.count) moves")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                MoveHistoryList(critiques: critiques)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Standalone full-screen history

struct MoveHistoryView: View {
    let critiques: [MoveCritique]

    var body: some View {
        ScrollView {
            MoveHistorySection(critiques: critiques)
                .padding()
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.9), Color.blue.opacity(0.1)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Move Analysis")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: MoveHistoryList.swift

struct MoveHistoryList: View {
    let critiques: [MoveCritique]
    @EnvironmentObject var analysisStore: AnalysisStore
    @EnvironmentObject var settings: AppSettings
    
    // Track selection locally for visual highlighting
    @State private var selectedID: UUID? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(critiques.reversed()) { critique in
                MoveCard(
                    critique: critique,
                    isSelected: selectedID == critique.id
                )
                .onTapGesture {
                    let isDeselecting = selectedID == critique.id
                    withAnimation(.spring(response: 0.3)) {
                        selectedID = isDeselecting ? nil : critique.id
                    }

                    if isDeselecting {
                        analysisStore.clearCritiqueSelection()
                    } else if let index = critiques.firstIndex(where: { $0.id == critique.id }) {
                        analysisStore.selectCritique(at: index)
                    }
                }
            }
        }
    }
}

// MARK: - Move Card

struct MoveCard: View {
    let critique: MoveCritique
    let isSelected: Bool
    @State private var showAlternatives = false
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Header ────────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 12) {

                // Piece icon from the active piece set
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(critique.side == "white"
                              ? Color.white.opacity(0.92)
                              : Color(white: 0.3))
                    PieceSetPieceView(
                        pieceType: critique.pieceType,
                        side:      critique.side,
                        pieceSet:  settings.pieceSet
                    )
                    .frame(width: 36, height: 36)
                }
                .frame(width: 52, height: 52)

                // Move number + actual move
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 4) {
                        Text(critique.moveNotation)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        if !critique.move.isEmpty, critique.move != critique.moveNotation {
                            Text(formatUCI(critique.move))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                    }
                    QualityBadge(quality: critique.classification)
                }

                Spacer()

                if let before = critique.scoreBefore, let after = critique.scoreAfter {
                    EvalChangeIndicator(before: before, after: after, side: critique.side)
                }
            }

            // ── Comment ───────────────────────────────────────────────────
            if !critique.comment.isEmpty {
                Text(critique.comment)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Engine's suggested line ───────────────────────────────────
            if critique.classification != .excellent,
               critique.classification != .book,
               !critique.suggestedLine.isEmpty {
                EngineLineView(
                    label: "Engine's best line",
                    moves: critique.suggestedLine,
                    accentColor: .blue
                )
            }

            // ── Position characteristics ──────────────────────────────────
            if let chars = critique.characteristics {
                CharacteristicsBadges(characteristics: chars)
            }

            // ── Alternatives ──────────────────────────────────────────────
            if !critique.alternatives.isEmpty {
                AlternativesSection(
                    alternatives: critique.alternatives,
                    isExpanded: $showAlternatives
                )
            }

            // ── AI Commentary (analysis mode, per-move) ───────────────────
            // Only shown when selected — avoids wall-of-text in the drawer.
            if isSelected {
                LLMNarrativeView(critiqueID: critique.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: qualityColor(critique.classification).opacity(0.2),
                        radius: isSelected ? 12 : 5,
                        x: 0, y: isSelected ? 5 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    LinearGradient(
                        colors: [qualityColor(critique.classification).opacity(isSelected ? 0.7 : 0.35), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.01 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func qualityColor(_ q: MoveQuality) -> Color {
        switch q {
        case .excellent:  return .green
        case .good:       return .blue
        case .inaccuracy: return .yellow
        case .mistake:    return .orange
        case .blunder:    return .red
        case .book:       return .purple
        case .unknown:    return .gray
        }
    }

    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from  = String(uci.prefix(2))
        let to    = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}

// MARK: - Quality Badge

struct QualityBadge: View {
    let quality: MoveQuality

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: quality.icon).font(.caption2.weight(.bold))
            Text(quality.rawValue).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(quality.color.opacity(0.2)))
        .overlay(Capsule().strokeBorder(quality.color.opacity(0.5), lineWidth: 1))
        .foregroundStyle(quality.color)
    }
}

// MARK: - Eval Change Indicator

struct EvalChangeIndicator: View {
    let before: Int
    let after: Int
    let side: String

    private var moverDelta: Int {
        side == "white" ? (after - before) : (before - after)
    }

    private var deltaColor: Color {
        moverDelta > 5 ? .green : moverDelta < -5 ? .red : .gray
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%+.2f", Double(after) / 100.0))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(after > 0 ? .green : after < 0 ? .red : .gray)
            HStack(spacing: 2) {
                Image(systemName: moverDelta > 5 ? "arrow.up.right"
                                : moverDelta < -5 ? "arrow.down.right" : "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(String(format: "%+.2f", Double(moverDelta) / 100.0))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(deltaColor)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
    }
}

// MARK: - Engine Line View

struct EngineLineView: View {
    let label: String
    let moves: [String]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(accentColor)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(moves.prefix(8).enumerated()), id: \.offset) { idx, uci in
                        Text(formatUCI(uci))
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(accentColor.opacity(idx == 0 ? 0.3 : 0.1))
                            )
                        if idx < min(moves.count, 8) - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    if moves.count > 8 {
                        Text("…").font(.caption).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(accentColor.opacity(0.08)))
    }

    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from  = String(uci.prefix(2))
        let to    = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}

// MARK: - Characteristics Badges

struct CharacteristicsBadges: View {
    let characteristics: PositionCharacteristics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Use new field names; fall back via legacy aliases if needed
                Badge(text: characteristics.position_type,
                      icon: positionTypeIcon(characteristics.position_type),
                      color: positionTypeColor(characteristics.position_type))
                Badge(text: characteristics.precision_required,
                      icon: precisionIcon(characteristics.precision_required),
                      color: precisionColor(characteristics.precision_required))
            }
            HStack(spacing: 6) {
                Badge(text: characteristics.eval_stability,
                      icon: stabilityIcon(characteristics.eval_stability),
                      color: stabilityColor(characteristics.eval_stability))
                Badge(text: characteristics.line_type,
                      icon: lineTypeIcon(characteristics.line_type),
                      color: .purple)
            }
            Text(characteristics.explanation)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
    }
}

struct Badge: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
        .foregroundStyle(color)
    }
}

// MARK: - Alternatives Section

struct AlternativesSection: View {
    let alternatives: [AlternativeMove]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                    Text("Alternative Lines")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(alternatives.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(alternatives) { alt in
                        AlternativeLineRow(alt: alt)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.15)))
    }
}

// MARK: - Alternative Line Row

struct AlternativeLineRow: View {
    let alt: AlternativeMove

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle()
                    .fill(rankColor(alt.rank))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text("\(alt.rank)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    )
                Text(formatUCI(alt.move))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if let cp = alt.scoreCP {
                    Text(String(format: "%+.2f", Double(cp) / 100.0))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(cp > 0 ? .green : cp < 0 ? .red : .gray)
                } else if let mate = alt.scoreMate {
                    Text(mate > 0 ? "M\(mate)" : "-M\(abs(mate))")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.purple)
                }
            }

            if !alt.pv.isEmpty {
                EngineLineView(label: "Line", moves: alt.pv, accentColor: rankColor(alt.rank))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.2)))
    }

    private func rankColor(_ r: Int) -> Color {
        switch r { case 1: return .yellow; case 2: return .gray; default: return .brown }
    }

    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from  = String(uci.prefix(2))
        let to    = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}
