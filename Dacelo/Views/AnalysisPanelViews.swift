// AnalysisPanelViews.swift
// Dacelo
//
// All analysis UI components, split by context:
//
//   PLAY MODE  (humanVsEngine / humanVsHuman)
//     AnalysisPanel         — lean panel: eval badge, WDL bar, characteristics
//                             badges, feedback text, best PV, mobility, depth
//
//   ANALYSIS MODE  (analysisOnly)
//     ReviewAnalysisPanel   — full deep-dive, two tabs:
//       Position tab  — WDL, badges (+ precision required), mobility,
//                       NNUEBreakdownView, PawnStructureView, KingSafetyView
//       Engine tab    — feedback text, best PV, depth/nodes
//     NNUEBreakdownView     — bidirectional bar chart for Stockfish NNUE terms
//                             (Material, Imbalance, Pawns, Mobility, King Safety,
//                              Threats, Passed Pawns, Space)
//     PawnStructureView     — isolated/doubled/passed pawn counts per side
//                             with coaching hints
//     KingSafetyView        — attacker count + castled status per side
//                             with coaching hints
//
//   PER-MOVE (embedded in MoveCard)
//     LLMNarrativeView      — reads LLMHookService.shared.narratives[critiqueID]
//                             shows typing indicator while in-flight
//
//   SHARED
//     WDLBar, MobilityBar, MaterialBalanceView
//     CharBadge, ConfidenceBadge, ModernEvalBadge, DepthNodeFooter
//     Free functions: sectionLabel(), coachHint()
//     Icon/colour helpers: stabilityIcon/Color, positionTypeIcon/Color,
//                          precisionIcon/Color, lineTypeIcon()

import SwiftUI

// ── Play-mode panel (lean) ─────────────────────────────────────────────────

struct AnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var game:     GameStore
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                engineBrainIcon(analyzing: analysis.isAnalysing, isReview: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine Analysis").font(.headline).foregroundStyle(.white)
                    if analysis.isAnalysing { analysingLabel }
                }
                Spacer()
                if let cp = analysis.scoreCP { ModernEvalBadge(scoreCP: cp) }
                expandToggle($isExpanded)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let wdl = analysis.wdl { WDLBar(wdl: wdl) }
                    if let c = analysis.currentCharacteristics { playBadges(c) }
                    feedbackLabel(analysis.lastFeedback)
                    if !analysis.currentPV.isEmpty {
                        EngineLineView(label: "Best line", moves: analysis.currentPV, accentColor: .blue)
                    }
                    if let mw = analysis.mobilityWhite, let mb = analysis.mobilityBlack, mw + mb > 0 {
                        MobilityBar(white: mw, black: mb)
                    }
                    if let d = analysis.depth, let n = analysis.nodes { DepthNodeFooter(depth: d, nodes: n) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle(review: false)
    }

    @ViewBuilder private func playBadges(_ c: PositionCharacteristics) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CharBadge(text: c.eval_stability,  icon: stabilityIcon(c.eval_stability),  color: stabilityColor(c.eval_stability))
                CharBadge(text: c.position_type,   icon: positionTypeIcon(c.position_type), color: positionTypeColor(c.position_type))
                CharBadge(text: c.line_type,       icon: lineTypeIcon(c.line_type),         color: .purple)
            }.padding(.vertical, 2)
        }
    }
}

// ── Review-mode panel (full deep-dive, tabbed) ────────────────────────────

struct ReviewAnalysisPanel: View {
    @EnvironmentObject var analysis: AnalysisStore
    @State private var tab = RTab.position
    @State private var isExpanded = true
    enum RTab: String, CaseIterable { case position = "Position"; case engine = "Engine" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                engineBrainIcon(analyzing: analysis.isAnalysing, isReview: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analysis Mode").font(.headline).foregroundStyle(.white)
                    if analysis.isAnalysing { analysingLabel }
                }
                Spacer()
                if let cp = analysis.scoreCP { ModernEvalBadge(scoreCP: cp) }
                expandToggle($isExpanded)
            }
            if isExpanded {
                HStack(spacing: 0) {
                    ForEach(RTab.allCases, id: \.self) { t in
                        Button { withAnimation(.spring(response: 0.25)) { tab = t } } label: {
                            Text(t.rawValue).font(.caption.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(tab == t ? Color.purple.opacity(0.25) : .clear))
                                .foregroundStyle(tab == t ? .purple : .white.opacity(0.45))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.05)))

                Group {
                    switch tab {
                    case .position: positionTab
                    case .engine:   engineTab
                    }
                }.transition(.opacity)
            }
        }
        .cardStyle(review: true)
    }

    private var positionTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let wdl = analysis.wdl { WDLBar(wdl: wdl) }
            if let c = analysis.currentCharacteristics { reviewBadges(c) }
            if let mw = analysis.mobilityWhite, let mb = analysis.mobilityBlack, mw + mb > 0 {
                MobilityBar(white: mw, black: mb)
            }
            if let nnue = analysis.nnue, !nnue.isEmpty {
                NNUEBreakdownView(terms: nnue)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if analysis.pawnStructure != nil {
                PawnStructureView().environmentObject(analysis)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if analysis.kingAttackersWhite != nil || analysis.kingAttackersBlack != nil {
                KingSafetyView().environmentObject(analysis)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let d = analysis.depth, let n = analysis.nodes { DepthNodeFooter(depth: d, nodes: n) }
        }
    }

    private var engineTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            feedbackLabel(analysis.lastFeedback)
            if !analysis.currentPV.isEmpty {
                EngineLineView(label: "Best line", moves: analysis.currentPV, accentColor: .purple)
            }
            if let d = analysis.depth, let n = analysis.nodes { DepthNodeFooter(depth: d, nodes: n) }
        }
    }

    @ViewBuilder private func reviewBadges(_ c: PositionCharacteristics) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CharBadge(text: c.eval_stability,    icon: stabilityIcon(c.eval_stability),       color: stabilityColor(c.eval_stability))
                CharBadge(text: c.position_type,     icon: positionTypeIcon(c.position_type),      color: positionTypeColor(c.position_type))
                CharBadge(text: c.precision_required, icon: precisionIcon(c.precision_required),   color: precisionColor(c.precision_required))
                CharBadge(text: c.line_type,         icon: lineTypeIcon(c.line_type),              color: .purple)
            }.padding(.vertical, 2)
        }
    }
}

// ── NNUE Breakdown ─────────────────────────────────────────────────────────

struct NNUEBreakdownView: View {
    let terms: [String: NNUETerm]
    private let order: [(String, String)] = [
        ("material","Material"),("imbalance","Imbalance"),("pawns","Pawns"),
        ("mobility","Mobility"),("king_safety","King Safety"),("threats","Threats"),
        ("passed_pawns","Passed Pawns"),("space","Space")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Stockfish NNUE Breakdown", icon: "chart.bar.fill", color: .orange)
            VStack(spacing: 5) {
                ForEach(order, id: \.0) { key, label in
                    if let t = terms[key] { NNUETermRow(label: label, term: t) }
                }
            }
            Text("Right = White · Left = Black · Values in pawns")
                .font(.caption2).foregroundStyle(.white.opacity(0.3))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.2), lineWidth: 1))
    }
}

struct NNUETermRow: View {
    let label: String; let term: NNUETerm
    private let cap: Double = 3.0
    private var wf: Double { min(max(term.white / cap, 0), 1) * 0.5 }
    private var bf: Double { min(max((-term.black) / cap, 0), 1) * 0.5 }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65)).frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width; let mid = w / 2
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06))
                    if wf > 0.01 {
                        HStack(spacing:0) { Spacer().frame(width:mid); RoundedRectangle(cornerRadius:2).fill(Color.white.opacity(0.75)).frame(width:w*wf); Spacer() }
                    }
                    if bf > 0.01 {
                        HStack(spacing:0) { Spacer(); RoundedRectangle(cornerRadius:2).fill(Color.white.opacity(0.22)).frame(width:w*bf); Spacer().frame(width:mid) }
                    }
                    Rectangle().fill(.white.opacity(0.18)).frame(width:1)
                }
            }
            .frame(height: 10)
            Text(String(format: "%+.2f", term.total))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(term.total > 0 ? .white.opacity(0.85) : .white.opacity(0.45))
                .frame(width: 42, alignment: .trailing)
        }
    }
}

// ── Pawn Structure ─────────────────────────────────────────────────────────

struct PawnStructureView: View {
    @EnvironmentObject var analysis: AnalysisStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Pawn Structure", icon: "squareshape.split.2x2", color: .yellow)
                Spacer()
                if let s = analysis.pawnStructure {
                    Text(s).font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                        .padding(.horizontal,8).padding(.vertical,3)
                        .background(Capsule().fill(Color.yellow.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.35),lineWidth:1))
                }
            }
            HStack(spacing:0) {
                pawnStat("Isolated", w: analysis.isolatedWhite, b: analysis.isolatedBlack, lower: true)
                Spacer()
                pawnStat("Doubled",  w: analysis.doubledWhite,  b: analysis.doubledBlack,  lower: true)
                Spacer()
                pawnStat("Passed",   w: analysis.passedWhite,   b: analysis.passedBlack,   lower: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let v = analysis.isolatedWhite,  v >= 2 { coachHint("♙ White has \(v) isolated pawns — they need active piece support.") }
                if let v = analysis.isolatedBlack,  v >= 2 { coachHint("♟ Black has \(v) isolated pawns — they need active piece support.") }
                if let v = analysis.passedWhite,    v > 0  { coachHint("♙ White has \(v) passed pawn\(v>1 ? "s":"") — advance with piece support.") }
                if let v = analysis.passedBlack,    v > 0  { coachHint("♟ Black has \(v) passed pawn\(v>1 ? "s":"") — advance with piece support.") }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius:12).fill(Color.yellow.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.yellow.opacity(0.18),lineWidth:1))
    }
    @ViewBuilder private func pawnStat(_ name: String, w: Int?, b: Int?, lower: Bool) -> some View {
        VStack(spacing:4) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing:5) { pill("W", v:w, lower:lower); pill("B", v:b, lower:lower) }
        }
    }
    @ViewBuilder private func pill(_ s: String, v: Int?, lower: Bool) -> some View {
        if let n = v {
            let c: Color = lower ? (n==0 ? .green : n==1 ? .yellow : .red) : (n==0 ? .white.opacity(0.3) : n==1 ? .yellow : .green)
            Text("\(s)\(n)").font(.system(size:11,weight:.bold,design:.monospaced)).foregroundStyle(c)
                .padding(.horizontal,6).padding(.vertical,2).background(Capsule().fill(c.opacity(0.12)))
        }
    }
}

// ── King Safety ───────────────────────────────────────────────────────────

struct KingSafetyView: View {
    @EnvironmentObject var analysis: AnalysisStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("King Safety", icon: "crown.fill", color: .cyan)
            HStack(spacing:12) {
                kingSide("White ♔", castled: analysis.kingCastledWhite, atk: analysis.kingAttackersWhite)
                Divider().background(.white.opacity(0.1)).frame(height:44)
                kingSide("Black ♚", castled: analysis.kingCastledBlack, atk: analysis.kingAttackersBlack)
            }
            VStack(alignment:.leading, spacing:3) {
                if analysis.kingCastledWhite == false { coachHint("♔ White king hasn't castled — consider castling soon.") }
                if analysis.kingCastledBlack == false { coachHint("♚ Black king hasn't castled — consider castling soon.") }
                if let v = analysis.kingAttackersWhite, v >= 3 { coachHint("♔ White king is under heavy attack (\(v) attackers in zone).") }
                if let v = analysis.kingAttackersBlack, v >= 3 { coachHint("♚ Black king is under heavy attack (\(v) attackers in zone).") }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius:12).fill(Color.cyan.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.cyan.opacity(0.18),lineWidth:1))
    }
    @ViewBuilder private func kingSide(_ label: String, castled: Bool?, atk: Int?) -> some View {
        VStack(alignment:.leading, spacing:5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            if let c = castled {
                HStack(spacing:4) {
                    Image(systemName: c ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.caption2).foregroundStyle(c ? .green : .orange)
                    Text(c ? "Castled" : "Exposed").font(.caption2.weight(.medium)).foregroundStyle(c ? .green : .orange)
                }
            }
            if let a = atk {
                let col: Color = a==0 ? .green : a<=2 ? .yellow : .red
                HStack(spacing:4) {
                    Image(systemName:"scope").font(.caption2).foregroundStyle(col)
                    Text("\(a) attacker\(a==1 ? "":"s")").font(.caption2.weight(.medium)).foregroundStyle(col)
                }
            }
        }
        .frame(maxWidth:.infinity, alignment:.leading)
    }
}

// ── LLM Narrative View (per-move) ─────────────────────────────────────────

struct LLMNarrativeView: View {
    let critiqueID: UUID
    @ObservedObject private var llm = LLMHookService.shared
    private var narrative: String? { llm.narrative(for: critiqueID) }
    private var loading: Bool      { llm.isGenerating(for: critiqueID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName:"text.bubble.fill").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                Text("AI Commentary").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                Spacer()
                if loading { ProgressView().controlSize(.mini).tint(.purple) }
                else if !llm.isAvailable { Text("LLM offline").font(.caption2).foregroundStyle(.white.opacity(0.3)) }
            }
            if loading {
                HStack(spacing:5) {
                    ForEach(0..<3) { i in
                        Circle().fill(Color.purple.opacity(0.6)).frame(width:6,height:6)
                            .scaleEffect(loading ? 1.0 : 0.5)
                            .animation(.easeInOut(duration:0.5).repeatForever().delay(Double(i)*0.15), value:loading)
                    }
                }.padding(.vertical,4)
            } else if let t = narrative {
                Text(t).font(.subheadline).foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal:false,vertical:true).lineSpacing(2)
                    .transition(.opacity).animation(.easeInOut(duration:0.35),value:t)
            } else if llm.isAvailable {
                Text("Commentary not yet available.").font(.subheadline).foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius:12).fill(Color.purple.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.purple.opacity(0.25),lineWidth:1))
    }
}

// ── WDL Bar ───────────────────────────────────────────────────────────────

struct WDLBar: View {
    let wdl: WDLResponse
    var body: some View {
        VStack(alignment:.leading, spacing:5) {
            GeometryReader { geo in
                HStack(spacing:1) {
                    RoundedRectangle(cornerRadius:3).fill(Color.white.opacity(0.9)).frame(width:geo.size.width*wdl.white)
                    RoundedRectangle(cornerRadius:0).fill(Color.white.opacity(0.3)).frame(width:geo.size.width*wdl.draw)
                    RoundedRectangle(cornerRadius:3).fill(Color.black.opacity(0.85)).frame(width:max(0,geo.size.width*wdl.black-2))
                }
                .clipShape(RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(.white.opacity(0.15),lineWidth:1))
            }.frame(height:10)
            HStack {
                Text("W \(Int((wdl.white*100).rounded()))%").wdlLbl()
                Spacer()
                Text("D \(Int((wdl.draw*100).rounded()))%").wdlLbl().opacity(0.65)
                Spacer()
                Text("B \(Int((wdl.black*100).rounded()))%").wdlLbl()
            }
        }
        .animation(.easeInOut(duration:0.4),value:wdl.white)
    }
}
private extension Text { func wdlLbl() -> some View { font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.white.opacity(0.7)) } }

// ── Mobility Bar ──────────────────────────────────────────────────────────

struct MobilityBar: View {
    let white: Int; let black: Int
    private var wf: Double { let t=Double(white+black); return t>0 ? Double(white)/t : 0.5 }
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:4) {
                Image(systemName:"arrow.left.and.right.circle").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                Text("Mobility").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("W\(white) · B\(black)").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            GeometryReader { geo in
                HStack(spacing:1) {
                    RoundedRectangle(cornerRadius:3).fill(Color.white.opacity(0.75)).frame(width:geo.size.width*wf)
                    RoundedRectangle(cornerRadius:3).fill(Color.white.opacity(0.2)).frame(width:max(0,geo.size.width*(1-wf)-1))
                }
                .clipShape(RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(.white.opacity(0.1),lineWidth:1))
            }.frame(height:7)
        }.animation(.easeInOut(duration:0.4),value:white)
    }
}

// ── Material Balance ──────────────────────────────────────────────────────

struct MaterialBalanceView: View {
    let balance: Int
    var body: some View { if balance != 0 { row } }
    private var row: some View {
        HStack(spacing:6) {
            if balance > 0 {
                Text("♙ ×\(balance)").font(.system(size:13,weight:.semibold)).foregroundStyle(.white.opacity(0.85))
                Text("+\(balance)").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundStyle(.green)
            } else {
                Text("♟ ×\(abs(balance))").font(.system(size:13,weight:.semibold)).foregroundStyle(.white.opacity(0.85))
                Text("\(balance)").font(.system(size:12,weight:.bold,design:.monospaced)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal,10).padding(.vertical,5)
        .background(Capsule().fill(.ultraThinMaterial).shadow(color:.black.opacity(0.2),radius:4,y:2))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1),lineWidth:1))
        .transition(.opacity.combined(with:.scale(scale:0.9)))
        .animation(.spring(response:0.3),value:balance)
    }
}

// ── Shared badges ─────────────────────────────────────────────────────────

struct ConfidenceBadge: View {
    let confidence: String
    var body: some View { CharBadge(text:confidence, icon:stabilityIcon(confidence), color:stabilityColor(confidence)) }
}

struct CharBadge: View {
    let text: String; let icon: String; let color: Color
    var body: some View {
        HStack(spacing:4) { Image(systemName:icon).font(.caption2.weight(.bold)); Text(text).font(.caption.weight(.semibold)) }
            .padding(.horizontal,9).padding(.vertical,4)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45),lineWidth:1))
            .foregroundStyle(color)
    }
}

struct DepthNodeFooter: View {
    let depth: Int; let nodes: Int
    var body: some View {
        Text("depth \(depth) · \(nodes >= 1_000_000 ? String(format:"%.1fM nodes",Double(nodes)/1_000_000) : nodes >= 1_000 ? String(format:"%.1fk nodes",Double(nodes)/1_000) : "\(nodes) nodes")")
            .font(.system(size:10,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.3))
            .frame(maxWidth:.infinity,alignment:.trailing)
    }
}

struct ModernEvalBadge: View {
    let scoreCP: Int
    var body: some View {
        VStack(spacing:2) {
            Text(String(format:"%+.2f",Double(scoreCP)/100.0)).font(.system(size:15,weight:.bold,design:.monospaced)).foregroundStyle(.white).fixedSize()
            Text("pawns").font(.system(size:9,weight:.medium)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal,12).padding(.vertical,8).frame(minWidth:70)
        .background(RoundedRectangle(cornerRadius:10).fill(LinearGradient(colors:[evalColor.opacity(0.8),evalColor.opacity(0.5)],startPoint:.topLeading,endPoint:.bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(.white.opacity(0.3),lineWidth:1))
    }
    private var evalColor: Color { scoreCP > 0 ? .green : scoreCP < 0 ? .red : .gray }
}

// ── Card style ────────────────────────────────────────────────────────────

private extension View {
    func cardStyle(review: Bool) -> some View {
        self.padding(16)
            .background(RoundedRectangle(cornerRadius:20).fill(.ultraThinMaterial).shadow(color:.black.opacity(0.2),radius:10,y:5))
            .overlay(RoundedRectangle(cornerRadius:20).strokeBorder(
                LinearGradient(colors: review ? [.purple.opacity(0.5),.blue.opacity(0.3)] : [.blue.opacity(0.3),.purple.opacity(0.3)],
                               startPoint:.topLeading,endPoint:.bottomTrailing),
                lineWidth: review ? 1.5 : 1))
            .animation(.easeInOut(duration:0.2),value:review)
    }
}

// ── Shared subview helpers ─────────────────────────────────────────────────

@ViewBuilder private func engineBrainIcon(analyzing: Bool, isReview: Bool) -> some View {
    ZStack {
        Circle().fill((isReview ? Color.purple : Color.blue).gradient.opacity(0.2)).frame(width:40,height:40)
        Image(systemName: isReview ? "chart.xyaxis.line" : "brain.head.profile")
            .font(.title3).foregroundStyle((isReview ? Color.purple : Color.blue).gradient)
            .rotationEffect(.degrees(analyzing ? 360 : 0))
            .animation(analyzing ? .linear(duration:2).repeatForever(autoreverses:false) : .default, value:analyzing)
    }
}

private var analysingLabel: some View {
    HStack(spacing:4) { ProgressView().controlSize(.mini).tint(.blue); Text("Analysing…").font(.caption).foregroundStyle(.white.opacity(0.7)) }
}

@ViewBuilder private func expandToggle(_ b: Binding<Bool>) -> some View {
    Button { withAnimation(.spring(response:0.3)) { b.wrappedValue.toggle() } } label: {
        Image(systemName: b.wrappedValue ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            .frame(width:28,height:28).background(Circle().fill(.white.opacity(0.08)))
    }.buttonStyle(.plain)
}

@ViewBuilder private func feedbackLabel(_ text: String) -> some View {
    Text(text.isEmpty ? "Make a move to get engine feedback." : text)
        .font(.subheadline)
        .foregroundStyle(text.isEmpty ? .white.opacity(0.5) : .white.opacity(0.9))
        .fixedSize(horizontal:false,vertical:true)
        .animation(.easeInOut,value:text)
}

@ViewBuilder func sectionLabel(_ title: String, icon: String, color: Color) -> some View {
    HStack(spacing:5) {
        Image(systemName:icon).font(.caption.weight(.semibold)).foregroundStyle(color)
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(color.opacity(0.85))
    }
}

@ViewBuilder func coachHint(_ text: String) -> some View {
    HStack(alignment:.top,spacing:5) {
        Image(systemName:"lightbulb.fill").font(.system(size:9)).foregroundStyle(.yellow.opacity(0.7)).padding(.top,2)
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal:false,vertical:true)
    }
}

// ── Icon/colour helpers ───────────────────────────────────────────────────

func stabilityIcon(_ s: String) -> String {
    switch s { case "Stable": return "checkmark.seal.fill"; case "Fluctuating": return "questionmark.circle.fill"; default: return "exclamationmark.triangle.fill" }
}
func stabilityColor(_ s: String) -> Color {
    switch s { case "Stable": return .green; case "Fluctuating": return .yellow; default: return .red }
}
func positionTypeIcon(_ p: String) -> String {
    switch p { case "Critical": return "flame.fill"; case "Complex": return "bolt.fill"; case "Unbalanced": return "scalemass.fill"; default: return "leaf.fill" }
}
func positionTypeColor(_ p: String) -> Color {
    switch p { case "Critical": return .red; case "Complex": return .orange; case "Unbalanced": return .blue; default: return .green }
}
func precisionIcon(_ p: String) -> String {
    switch p { case "Very High": return "star.circle.fill"; case "High": return "3.circle.fill"; case "Moderate": return "2.circle.fill"; default: return "1.circle.fill" }
}
func precisionColor(_ p: String) -> Color {
    switch p { case "Very High": return .red; case "High": return .orange; case "Moderate": return .yellow; default: return .green }
}
func lineTypeIcon(_ l: String) -> String {
    switch l { case "Forcing": return "bolt.circle.fill"; case "Tactical": return "scope"; case "Committal": return "arrow.right.circle.fill"; case "Flexible": return "arrow.triangle.branch"; default: return "tortoise.fill" }
}
