// MoveHistoryView.swift
// Dacelo
//
// Modern move history with critique cards and characteristics

import SwiftUI

struct MoveHistoryView: View {
    let critiques: [MoveCritique]
    @State private var selectedMove: MoveCritique? = nil
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(critiques) { critique in
                    MoveCard(critique: critique, isSelected: selectedMove?.id == critique.id)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3)) {
                                selectedMove = selectedMove?.id == critique.id ? nil : critique
                            }
                        }
                }
            }
            .padding()
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.9), Color.blue.opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Move Analysis")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Move Card

struct MoveCard: View {
    let critique: MoveCritique
    let isSelected: Bool
    @State private var showAlternatives = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                // Move number and piece icon
                VStack(spacing: 4) {
                    Text("\(critique.moveNumber)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text(critique.side == "white" ? "♔" : "♚")
                        .font(.title2)
                }
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(critique.side == "white" ? .white.opacity(0.15) : .black.opacity(0.3))
                )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(critique.moveNotation)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    
                    QualityBadge(quality: critique.classification)
                }
                
                Spacer()
                
                // Eval change
                if let before = critique.scoreBefore,
                   let after = critique.scoreAfter {
                    EvalChangeIndicator(before: before, after: after)
                }
            }
            
            // Comment
            if !critique.comment.isEmpty {
                Text(critique.comment)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 4)
            }
            
            // Position characteristics
            if let chars = critique.characteristics {
                CharacteristicsBadges(characteristics: chars)
                    .padding(.top, 4)
            }
            
            // Alternatives (expandable)
            if !critique.alternatives.isEmpty {
                AlternativesSection(
                    alternatives: critique.alternatives,
                    isExpanded: $showAlternatives
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: qualityColor(critique.classification).opacity(0.3),
                       radius: isSelected ? 15 : 8,
                       x: 0, y: isSelected ? 8 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(
                        colors: [qualityColor(critique.classification).opacity(0.5), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    private func qualityColor(_ quality: MoveQuality) -> Color {
        switch quality {
        case .excellent:  return .green
        case .good:       return .blue
        case .inaccuracy: return .yellow
        case .mistake:    return .orange
        case .blunder:    return .red
        case .book:       return .purple
        case .unknown:    return .gray
        }
    }
}

// MARK: - Quality Badge

struct QualityBadge: View {
    let quality: MoveQuality
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(quality.rawValue)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.2))
        )
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
        )
        .foregroundStyle(color)
    }
    
    private var color: Color {
        switch quality {
        case .excellent:  return .green
        case .good:       return .blue
        case .inaccuracy: return .yellow
        case .mistake:    return .orange
        case .blunder:    return .red
        case .book:       return .purple
        case .unknown:    return .gray
        }
    }
    
    private var icon: String {
        switch quality {
        case .excellent:  return "star.fill"
        case .good:       return "checkmark.circle.fill"
        case .inaccuracy: return "exclamationmark.triangle.fill"
        case .mistake:    return "xmark.circle.fill"
        case .blunder:    return "flame.fill"
        case .book:       return "book.fill"
        case .unknown:    return "questionmark.circle"
        }
    }
}

// MARK: - Eval Change Indicator

struct EvalChangeIndicator: View {
    let before: Int
    let after: Int
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(formatScore(after))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(scoreColor(after))
            
            HStack(spacing: 2) {
                Image(systemName: arrow)
                    .font(.caption2)
                    .foregroundStyle(changeColor)
                Text(formatDelta)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(changeColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var delta: Int { after - before }
    
    private var formatDelta: String {
        String(format: "%+.2f", Double(abs(delta)) / 100.0)
    }
    
    private func formatScore(_ score: Int) -> String {
        String(format: "%+.2f", Double(score) / 100.0)
    }
    
    private func scoreColor(_ score: Int) -> Color {
        score > 0 ? .green : score < 0 ? .red : .gray
    }
    
    private var changeColor: Color {
        delta > 0 ? .green : delta < 0 ? .red : .gray
    }
    
    private var arrow: String {
        delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "arrow.right"
    }
}

// MARK: - Characteristics Badges

struct CharacteristicsBadges: View {
    let characteristics: PositionCharacteristics
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(
                    text: characteristics.sharpness,
                    icon: "flame.fill",
                    color: sharpnessColor
                )
                
                Badge(
                    text: characteristics.difficulty,
                    icon: difficultyIcon,
                    color: .blue
                )
                
                Badge(
                    text: characteristics.margin_for_error,
                    icon: "target",
                    color: .purple
                )
            }
            
            Text(characteristics.explanation)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.2))
        )
    }
    
    private var sharpnessColor: Color {
        switch characteristics.sharpness {
        case "Sharp":    return .red
        case "Tactical": return .orange
        case "Balanced": return .blue
        case "Quiet":    return .green
        default:         return .gray
        }
    }
    
    private var difficultyIcon: String {
        switch characteristics.difficulty {
        case "Beginner":     return "1.circle.fill"
        case "Intermediate": return "2.circle.fill"
        case "Advanced":     return "3.circle.fill"
        case "Expert":       return "star.circle.fill"
        default:             return "circle.fill"
        }
    }
}

struct Badge: View {
    let text: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
        .foregroundStyle(color)
    }
}

// MARK: - Alternatives Section

struct AlternativesSection: View {
    let alternatives: [AlternativeMove]
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                    Text("Alternative Moves")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(alternatives.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(alternatives) { alt in
                        HStack {
                            Circle()
                                .fill(rankColor(alt.rank))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Text("\(alt.rank)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                )
                            
                            Text(alt.move)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                                .foregroundStyle(.white)
                            
                            Spacer()
                            
                            if let cp = alt.scoreCP {
                                Text(String(format: "%+.2f", Double(cp) / 100.0))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(cp > 0 ? .green : cp < 0 ? .red : .gray)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.black.opacity(0.2))
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.15))
        )
    }
    
    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .brown
        default: return .blue
        }
    }
}

#Preview {
    NavigationStack {
        MoveHistoryView(critiques: [
            MoveCritique(
                moveNumber: 1,
                side: "white",
                move: "e2e4",
                moveNotation: "e4",
                scoreBefore: 20,
                scoreAfter: 35,
                classification: .excellent,
                comment: "Best move!",
                alternatives: [
                    AlternativeMove(rank: 1, move: "e2e4", scoreCP: 35, scoreMate: nil),
                    AlternativeMove(rank: 2, move: "d2d4", scoreCP: 28, scoreMate: nil)
                ],
                characteristics: PositionCharacteristics(
                    sharpness: "Tactical",
                    difficulty: "Intermediate",
                    margin_for_error: "Moderate",
                    line_type: "Flexible",
                    explanation: "Several decent moves with tactical possibilities."
                )
            )
        ])
    }
}
