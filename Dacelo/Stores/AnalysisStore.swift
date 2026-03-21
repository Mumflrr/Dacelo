// AnalysisStore.swift
// Dacelo
//
// Drives all chess analysis UI. Observes the live ChessStore and fires an
// analyse request to EngineService after every move.
//
// Published state is split by cost:
//
//   BOTH MODES (every move)
//     scoreCP, wdl, feedback         — engine eval + human-readable summary
//     alternatives, currentPV        — MultiPV lines from the eval engine
//     materialBalance, mobility*     — python-chess arithmetic (free)
//     gamePhase                      — Opening / Middlegame / Endgame
//     currentCharacteristics         — position type, precision, stability, line type
//     moveCritiques                  — full history, one entry per move
//
//   ANALYSIS MODE ONLY  (deep=true, runs concurrently)
//     nnue                           — Stockfish NNUE term breakdown
//     pawnStructure, isolated*, doubled*, passed*  — python-chess pawn analysis
//     kingAttackers*, kingCastled*   — python-chess king safety
//
//   LLM NARRATIVES
//     llmContexts: [UUID: LLMAnalysisContext]  — built every move in analysis mode
//     LLM calls fire immediately per move (background). Displayed only when the
//     user selects a MoveCard in analysis mode. fillMissingNarratives() fills
//     any gaps if the LLM was offline during play.

import Foundation
import Combine

@MainActor
final class AnalysisStore: ObservableObject {

    // MARK: - Published State

    @Published var moveCritiques:          [MoveCritique]              = []
    @Published var lastFeedback:           String                      = ""
    /// Arrows shown on the board: index 0 = best (yellow), 1 = 2nd (cyan), 2 = 3rd (orange).
    @Published var bestMoveArrows:         [(from: String, to: String)]   = []
    @Published var isRequestingHint:       Bool                        = false
    enum AnalysisStage {
        case idle
        case evaluating       // engine thinking
        case computingMetrics // python-chess pawn/king/phase work
        case generatingNarrative // LLM
    }
    @Published var analysisStage:          AnalysisStage               = .idle
    @Published var scoreCP:                Int?                        = nil
    @Published var wdl:                    WDLResponse?                = nil
    @Published var materialBalance:        Int?                        = nil
    @Published var mobilityWhite:          Int?                        = nil
    @Published var mobilityBlack:          Int?                        = nil
    @Published var depth:                  Int?                        = nil
    @Published var nodes:                  Int?                        = nil
    /// Raw score_cp from the eval engine (non-normalised, from side-to-move perspective).
    // FIX: was never set from any response — now populated from result.score_cp
    @Published var engineScoreCP:          Int?                        = nil
    /// Score from the secondary (best-move) engine, when it differs from evalEngine.
    @Published var deepScoreCP:            Int?                        = nil
    @Published var nnue:                   [String: NNUETerm]?         = nil
    @Published var currentCharacteristics: PositionCharacteristics?    = nil
    @Published var currentPV:             [String]                     = []
    @Published var selectedCritiqueIndex:  Int?                        = nil
    // True when the user is browsing a past position (board and panel show historical data).
    @Published var isReviewingHistory:     Bool                        = false
    @Published var gamePhase:             String?                      = nil
    /// LLM context keyed by MoveCritique.id — used for lazy narrative generation.
    /// Built during analysis, consumed lazily when the user navigates to a move.
    private(set) var llmContexts: [UUID: LLMAnalysisContext] = [:]
    // Pawn structure (analysis mode only)
    @Published var isolatedWhite:         Int?                         = nil
    @Published var isolatedBlack:         Int?                         = nil
    @Published var doubledWhite:          Int?                         = nil
    @Published var doubledBlack:          Int?                         = nil
    @Published var passedWhite:           Int?                         = nil
    @Published var passedBlack:           Int?                         = nil
    @Published var pawnStructure:         String?                      = nil
    // King safety (analysis mode only)
    @Published var kingAttackersWhite:    Int?                         = nil
    @Published var kingAttackersBlack:    Int?                         = nil
    @Published var kingCastledWhite:      Bool?                        = nil
    @Published var kingCastledBlack:      Bool?                        = nil

    var canGoBack: Bool {
        if gameStore?.isExploringScratch == true { return gameStore?.canGoBackInScratch ?? false }
        return !moveCritiques.isEmpty && (selectedCritiqueIndex ?? moveCritiques.count - 1) > 0
    }
    var canGoForward: Bool {
        if gameStore?.isExploringScratch == true { return gameStore?.canGoForwardInScratch ?? false }
        return selectedCritiqueIndex != nil && selectedCritiqueIndex! < moveCritiques.count - 1
    }
    var isAnalysing: Bool { analysisStage != .idle }

    func goBack() {
        if gameStore?.isExploringScratch == true {
            gameStore?.goBackInHistory()
            return
        }
        guard !moveCritiques.isEmpty else { return }
        let current = selectedCritiqueIndex ?? (moveCritiques.count - 1)
        selectCritique(at: max(0, current - 1))
    }

    func goForward() {
        if gameStore?.isExploringScratch == true {
            gameStore?.goForwardInScratch()
            return
        }
        guard let idx = selectedCritiqueIndex else { return }
        let next = idx + 1
        if next >= moveCritiques.count {
            clearCritiqueSelection()
        } else {
            selectCritique(at: next)
        }
    }
    
    // MARK: - History navigation

    /// Select a historical critique: restores the board position and all analysis
    /// panel state from the stored snapshot. Fires LLM narrative if not yet ready.
    func selectCritique(at index: Int) {
        guard moveCritiques.indices.contains(index) else { return }
        let critique = moveCritiques[index]
        selectedCritiqueIndex = index
        isReviewingHistory    = true

        // Save live panel state the first time we enter history so we can restore it
        if livePanelSnapshot == nil {
            livePanelSnapshot = PositionSnapshot(
                scoreCP: scoreCP, scoreMate: nil, wdl: wdl,
                feedback: lastFeedback, pv: currentPV,
                depth: depth, nodes: nodes, gamePhase: gamePhase,
                materialBalance: materialBalance,
                mobilityWhite: mobilityWhite, mobilityBlack: mobilityBlack,
                nnue: nnue, pawnStructure: pawnStructure,
                isolatedWhite: isolatedWhite, isolatedBlack: isolatedBlack,
                doubledWhite: doubledWhite, doubledBlack: doubledBlack,
                passedWhite: passedWhite, passedBlack: passedBlack,
                kingAttackersWhite: kingAttackersWhite,
                kingAttackersBlack: kingAttackersBlack,
                kingCastledWhite: kingCastledWhite,
                kingCastledBlack: kingCastledBlack
            )
        }

        // Tear down any existing scratch before showing the new position.
        gameStore?.endScratchExploration()
        gameStore?.showHistoryPosition(fen: critique.fen)

        let s = critique.snapshot
        scoreCP                = critique.scoreAfter
        wdl                    = s.wdl
        lastFeedback           = s.feedback
        currentPV              = s.pv
        depth                  = s.depth
        nodes                  = s.nodes
        gamePhase              = s.gamePhase
        currentCharacteristics = critique.characteristics
        materialBalance        = s.materialBalance
        mobilityWhite          = s.mobilityWhite
        mobilityBlack          = s.mobilityBlack
        nnue                   = s.nnue
        pawnStructure          = s.pawnStructure
        isolatedWhite          = s.isolatedWhite
        isolatedBlack          = s.isolatedBlack
        doubledWhite           = s.doubledWhite
        doubledBlack           = s.doubledBlack
        passedWhite            = s.passedWhite
        passedBlack            = s.passedBlack
        kingAttackersWhite     = s.kingAttackersWhite
        kingAttackersBlack     = s.kingAttackersBlack
        kingCastledWhite       = s.kingCastledWhite
        kingCastledBlack       = s.kingCastledBlack
        bestMoveArrows         = []

        requestNarrativeIfNeeded(for: critique)
        prevEval = critique.scoreAfter
    }

    /// Deselect any critique and return to the live game position.
    func clearCritiqueSelection(preservePanelState: Bool = false) {
        selectedCritiqueIndex = nil
        isReviewingHistory    = false
        gameStore?.clearHistoryReview()
        if preservePanelState {
            return
        }
        // Restore live state if we snapshotted it; otherwise clear
        if let snap = livePanelSnapshot {
            scoreCP                = snap.scoreCP
            wdl                    = snap.wdl
            lastFeedback           = snap.feedback
            currentPV              = snap.pv
            depth                  = snap.depth
            nodes                  = snap.nodes
            gamePhase              = snap.gamePhase
            materialBalance        = snap.materialBalance
            mobilityWhite          = snap.mobilityWhite
            mobilityBlack          = snap.mobilityBlack
            nnue                   = snap.nnue
            pawnStructure          = snap.pawnStructure
            isolatedWhite          = snap.isolatedWhite
            isolatedBlack          = snap.isolatedBlack
            doubledWhite           = snap.doubledWhite
            doubledBlack           = snap.doubledBlack
            passedWhite            = snap.passedWhite
            passedBlack            = snap.passedBlack
            kingAttackersWhite     = snap.kingAttackersWhite
            kingAttackersBlack     = snap.kingAttackersBlack
            kingCastledWhite       = snap.kingCastledWhite
            kingCastledBlack       = snap.kingCastledBlack
            bestMoveArrows         = []
            livePanelSnapshot      = nil
        } else {
            clearLivePanel()
        }
    }

    // MARK: - Private

    private let engine:       EngineService
    private weak var gameStore:    GameStore?
    private weak var appSettings:  AppSettings?
    private var cancellables: Set<AnyCancellable> = []
    private var scratchCancellables: Set<AnyCancellable> = []

    private var prevEval:  Int? = nil
    private var moveCount: Int  = 0
    private var tail: Task<Void, Never>?

    // Snapshot of live panel state saved when user enters history review,
    // so we can restore it when they return to the live position.
    private var livePanelSnapshot: PositionSnapshot?

    // MARK: - Init

    init(engine: EngineService) {
        self.engine = engine
    }

    // MARK: - Public API

    // Call this ONCE from AppStore.init(), never again.
    func observeScratch(_ gameStore: GameStore) {
        gameStore.$scratchGame
            .compactMap { $0 }
            .removeDuplicates { $0.board.fen == $1.board.fen }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] game in
                self?.handlePositionChange(fen: game.board.fen,
                                           history: game.history,
                                           appendToHistory: false)
            }
            .store(in: &scratchCancellables)
    }

    func observe(_ gameStore: GameStore, settings: AppSettings? = nil, preserveHistory: Bool = false) {
        self.gameStore   = gameStore
        self.appSettings = settings
        cancellables.removeAll()
        if !preserveHistory { clearHistory() }

        gameStore.$game
            .removeDuplicates { $0.board.fen == $1.board.fen }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] game in
                self?.handlePositionChange(fen: game.board.fen,
                                           history: game.history,
                                           appendToHistory: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - Hint

    /// Show hint arrows for the top `count` moves (1–3).
    func requestHint(count: Int = 1) {
        guard let fen = gameStore?.displayFEN, !fen.isEmpty, !isRequestingHint else { return }
        let clampedCount = max(1, min(count, 3))
        isRequestingHint = true
        Task {
            do {
                let result = try await engine.analyse(fen: fen, movetime: 1500)
                var arrows: [(from: String, to: String)] = []
                if let from = result.from, let to = result.to, !from.isEmpty, !to.isEmpty {
                    arrows.append((from: from, to: to))
                }
                for alt in (result.alternatives ?? []).prefix(clampedCount - 1) {
                    if let f = alt.from, let t = alt.to, !f.isEmpty, !t.isEmpty {
                        arrows.append((from: f, to: t))
                    }
                }
                bestMoveArrows = arrows
            } catch {
                print("[AnalysisStore] Hint failed: \(error.localizedDescription)")
            }
            isRequestingHint = false
        }
    }

    func clearHistory() {
        moveCritiques.removeAll()
        llmContexts.removeAll()
        selectedCritiqueIndex = nil
        livePanelSnapshot     = nil
        prevEval  = nil
        moveCount = 0
        clearLivePanel()
        LLMHookService.shared.clearNarratives()
    }

    // MARK: - Lazy LLM narrative request

    /// Call when the user navigates to a specific critique in post-game review.
    /// Fires the LLM request if not already generated or in-flight.
    func requestNarrativeIfNeeded(for critique: MoveCritique) {
        guard let ctx = llmContexts[critique.id] else { return }
        LLMHookService.shared.requestNarrative(for: critique.id, context: ctx)
    }

    func clearLivePanel() {
        isReviewingHistory     = false
        lastFeedback           = ""
        bestMoveArrows         = []
        scoreCP                = nil
        wdl                    = nil
        materialBalance        = nil
        mobilityWhite          = nil
        mobilityBlack          = nil
        depth                  = nil
        nodes                  = nil
        engineScoreCP          = nil
        deepScoreCP            = nil
        nnue                   = nil
        currentCharacteristics = nil
        currentPV              = []
        gamePhase              = nil
        isolatedWhite          = nil
        isolatedBlack          = nil
        doubledWhite           = nil
        doubledBlack           = nil
        passedWhite            = nil
        passedBlack            = nil
        pawnStructure          = nil
        kingAttackersWhite     = nil
        kingAttackersBlack     = nil
        kingCastledWhite       = nil
        kingCastledBlack       = nil
    }

    // MARK: - Position change handler

    private func handlePositionChange(fen: String, history: [MoveRecord], appendToHistory: Bool) {
        guard !fen.hasPrefix("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR") else { return }

        bestMoveArrows = []

        let fenParts      = fen.split(separator: " ").map(String.init)
        let activeColor   = fenParts.count > 1 ? fenParts[1] : "w"
        let sideJustMoved = activeColor == "w" ? "black" : "white"

        let fullMove   = Int(fenParts.count > 5 ? fenParts[5] : "1") ?? 1
        let displayNum = sideJustMoved == "white" ? fullMove : max(1, fullMove - 1)
        let movePrefix = sideJustMoved == "white" ? "\(displayNum)." : "\(displayNum)..."

        // Derive last move and piece type from our own MoveRecord history.
        let lastRecord = history.last
        let lastUCI    = lastRecord?.move.uci ?? ""

        let pieceType: String = {
            guard let record = lastRecord else { return "p" }
            let dest = record.board.squares[record.move.to]
            switch dest?.type {
            case .knight: return "n"
            case .bishop: return "b"
            case .rook:   return "r"
            case .queen:  return "q"
            case .king:   return "k"
            default:      return "p"
            }
        }()

        let capturedMoveCount  = appendToHistory ? { moveCount += 1; return moveCount }() : moveCount
        let capturedPrevEval   = prevEval
        let capturedPieceType  = pieceType
        let isAnalysisMode     = gameStore?.gameMode == .analysisOnly
        let capturedNNUEEngine = isAnalysisMode ? (appSettings?.nnueEngine ?? "stockfish") : ""

        enqueue {
            await self.runMoveAnalysis(
                fen:             fen,
                side:            sideJustMoved,
                movePrefix:      movePrefix,
                lastUCI:         lastUCI,
                pieceType:       capturedPieceType,
                moveNumber:      capturedMoveCount,
                prevEval:        capturedPrevEval,
                isAnalysisMode:  isAnalysisMode,
                nnueEngine:      capturedNNUEEngine,
                appendToHistory: appendToHistory
            )
        }
    }

    // MARK: - Analysis

    private func runMoveAnalysis(
        fen:             String,
        side:            String,
        movePrefix:      String,
        lastUCI:         String,
        pieceType:       String,
        moveNumber:      Int,
        prevEval:        Int?,
        isAnalysisMode:  Bool,
        nnueEngine:      String,
        appendToHistory: Bool
    ) async {
        

        do {
            analysisStage = .evaluating
            let result = try await engine.analyse(
                fen:            fen,
                movetime:       appSettings?.evalTimeMs     ?? 2000,
                evalEngine:     appSettings?.evalEngine     ?? "stockfish",
                bestMoveEngine: appSettings?.bestMoveEngine ?? "lc0",
                nnueEngine:     nnueEngine,
                deep:           isAnalysisMode
            )
            analysisStage = .computingMetrics
            let fenParts      = fen.split(separator: " ").map(String.init)
            let activeColor   = fenParts.count > 1 ? fenParts[1] : "w"
            let normScore     = normalise(cp: result.score_cp, activeColor: activeColor)

            let effectivePrevEval = prevEval ?? 0

            let classification = classifyMove(
                prevEval:     effectivePrevEval,
                currEval:     normScore,
                side:         side,
                alternatives: result.alternatives,
                activeColor:  activeColor
            )

            let alternatives = (result.alternatives ?? []).map {
                AlternativeMove(
                    rank:      $0.rank,
                    move:      $0.move ?? "",
                    scoreCP:   normalise(cp: $0.score_cp, activeColor: activeColor),
                    scoreMate: $0.score_mate,
                    pv:        $0.pv ?? []
                )
            }

            let cpLoss: Int? = {
                guard let curr = normScore else { return nil }
                let loss = side == "white"
                    ? (effectivePrevEval - curr)
                    : (curr - effectivePrevEval)
                return max(0, loss)
            }()

            let snapshot = PositionSnapshot(
                scoreCP:            normScore,
                scoreMate:          result.score_mate,
                wdl:                result.wdl,
                feedback:           result.feedback ?? "",
                pv:                 result.pv ?? [],
                depth:              result.depth,
                nodes:              result.nodes,
                gamePhase:          result.game_phase,
                materialBalance:    result.material_balance,
                mobilityWhite:      result.mobility_white,
                mobilityBlack:      result.mobility_black,
                nnue:               result.nnue,
                pawnStructure:      result.pawn_structure,
                isolatedWhite:      result.isolated_white,
                isolatedBlack:      result.isolated_black,
                doubledWhite:       result.doubled_white,
                doubledBlack:       result.doubled_black,
                passedWhite:        result.passed_white,
                passedBlack:        result.passed_black,
                kingAttackersWhite: result.king_attackers_white,
                kingAttackersBlack: result.king_attackers_black,
                kingCastledWhite:   result.king_castled_white,
                kingCastledBlack:   result.king_castled_black
            )

            let critique = MoveCritique(
                moveNumber:      moveNumber,
                side:            side,
                move:            lastUCI,
                moveNotation:    movePrefix,
                pieceType:       pieceType,
                scoreBefore:     prevEval,
                scoreAfter:      normScore,
                classification:  classification.quality,
                comment:         classification.comment,
                alternatives:    alternatives,
                characteristics: result.characteristics,
                suggestedLine:   result.pv ?? [],
                fen:             fen,
                snapshot:        snapshot
            )

            self.prevEval               = normScore
            self.scoreCP                = normScore
            self.engineScoreCP          = result.score_cp
            self.wdl                    = result.wdl
            self.materialBalance        = result.material_balance
            self.mobilityWhite          = result.mobility_white
            self.mobilityBlack          = result.mobility_black
            self.depth                  = result.depth
            self.nodes                  = result.nodes
            self.deepScoreCP            = result.deep_score_cp
            self.nnue                   = result.nnue
            self.lastFeedback           = result.feedback ?? ""
            self.currentCharacteristics = result.characteristics
            self.currentPV              = result.pv ?? []
            self.gamePhase              = result.game_phase
            self.isolatedWhite          = result.isolated_white
            self.isolatedBlack          = result.isolated_black
            self.doubledWhite           = result.doubled_white
            self.doubledBlack           = result.doubled_black
            self.passedWhite            = result.passed_white
            self.passedBlack            = result.passed_black
            self.pawnStructure          = result.pawn_structure
            self.kingAttackersWhite     = result.king_attackers_white
            self.kingAttackersBlack     = result.king_attackers_black
            self.kingCastledWhite       = result.king_castled_white
            self.kingCastledBlack       = result.king_castled_black

            
            if isAnalysisMode {
                var arrows: [(from: String, to: String)] = []
                if let from = result.from, let to = result.to, !from.isEmpty, !to.isEmpty {
                    arrows.append((from: from, to: to))
                }
                for alt in (result.alternatives ?? []).prefix(2) {
                    if let f = alt.from, let t = alt.to, !f.isEmpty, !t.isEmpty {
                        arrows.append((from: f, to: t))
                    }
                }
                self.bestMoveArrows = arrows
            } else {
                self.bestMoveArrows = []
            }

            // Only record history for real game moves, never scratch
            if appendToHistory {
                moveCritiques.append(critique)
                self.prevEval = normScore

                if isAnalysisMode {
                    let ctx = buildCoachingRequest(
                        fen:          fen,
                        lastUCI:      lastUCI,
                        side:         side,
                        movePrefix:   movePrefix,
                        result:       result,
                        normScore:    normScore,
                        prevEvalSnap: prevEval,
                        cpLoss:       cpLoss,
                        classification: classification.quality.rawValue,
                        alternatives: alternatives
                    )
                    llmContexts[critique.id] = ctx
                    LLMHookService.shared.requestNarrative(for: critique.id, context: ctx)
                }
            }
            analysisStage = .idle
            

        } catch {
            analysisStage = .idle
            print("[AnalysisStore] Analysis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Serial queue

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    // MARK: - Score normalisation

    private func normalise(cp: Int?, activeColor: String) -> Int? {
        guard let cp else { return nil }
        return activeColor == "w" ? cp : -cp
    }

    // MARK: - Move classification

    private func classifyMove(
        prevEval:     Int,
        currEval:     Int?,
        side:         String,
        alternatives: [AlternativeMoveResponse]?,
        activeColor:  String
    ) -> (quality: MoveQuality, comment: String) {

        guard let curr = currEval else {
            return (.unknown, "")
        }

        let cpLoss    = side == "white" ? (prevEval - curr) : (curr - prevEval)
        let bestAlt   = alternatives?.first(where: { $0.score_cp != nil })
        let bestMove  = bestAlt?.move ?? ""
        let betterStr = bestMove.isEmpty ? "" : " Engine prefers \(formatUCI(bestMove))."
        let lostPawns = Double(max(0, cpLoss)) / 100.0

        switch cpLoss {
        case ..<10:
            return (.excellent, "Best move! The engine agrees this is the top choice.")
        case ..<25:
            return (.good, "Good move — only \(cpLoss)cp from optimal.\(betterStr)")
        case ..<50:
            return (.inaccuracy,
                    String(format: "Inaccuracy — %.2f pawns from optimal.\(betterStr) A better continuation was available.", lostPawns))
        case ..<100:
            return (.mistake,
                    String(format: "Mistake — %.2f pawns lost.\(betterStr) This significantly weakens your position.", lostPawns))
        default:
            return (.blunder,
                    String(format: "Blunder — %.2f pawns lost!\(betterStr) This fundamentally changes the game's outcome.", lostPawns))
        }
    }

    /// Fill any missing narratives — call on entering review mode to catch
    /// any that failed during play (e.g. LLM was offline).
    func fillMissingNarratives() {
        let pairs: [(id: UUID, context: ChessCoachingRequest)] = moveCritiques.compactMap { c in
            guard let ctx = llmContexts[c.id] else { return nil }
            return (id: c.id, context: ctx)
        }
        LLMHookService.shared.fillMissingNarratives(critiques: pairs)
    }

    // MARK: - Coaching request builder

    /// Builds a pre-digested ChessCoachingRequest from raw analysis data.
    /// Raw numbers (NNUE floats, mobility counts, isolated pawn counts) are
    /// converted to human-readable tactical flags here.
    private func buildCoachingRequest(
        fen:            String,
        lastUCI:        String,
        side:           String,
        movePrefix:     String,
        result:         AnalysisResponse,
        normScore:      Int?,
        prevEvalSnap:   Int?,
        cpLoss:         Int?,
        classification: String,
        alternatives:   [AlternativeMove]
    ) -> ChessCoachingRequest {

        // ── Best alternative ──────────────────────────────────────────────
        let bestAlt      = alternatives.first
        let bestMoveUCI  = bestAlt?.move != lastUCI ? bestAlt?.move : nil
        let bestMoveEval = bestAlt?.scoreCP.map { Double($0) / 100.0 }

        // ── Eval ──────────────────────────────────────────────────────────
        let evalAfter = normScore.map { Double($0) / 100.0 }

        // ── Depth drift profile ───────────────────────────────────────────
        // Derived from shallow (score_cp) vs deep (deep_score_cp).
        // Tells the LLM whether this move looks better or worse at depth.
        let depthProfile: String? = {
            guard let shallow = result.score_cp,
                  let deep    = result.deep_score_cp else { return nil }
            let drift = deep - shallow
            switch drift {
            case  60...:   return "deepening"   // score improves at depth
            case ..<(-60): return "mirage"      // collapses — hidden refutation
            case -20...20: return "stable"      // consistent at all depths
            default:       return "sharp"       // oscillating
            }
        }()

        // ── Tactical flags (pre-digested) ─────────────────────────────────
        // Each flag is a plain English sentence.
        var flags: [String] = []

        let wAtk = result.king_attackers_white ?? 0
        let bAtk = result.king_attackers_black ?? 0
        let wCas = result.king_castled_white ?? true
        let bCas = result.king_castled_black ?? true

        if !wCas && wAtk >= 2 {
            flags.append("White king is uncastled and under heavy attack (\(wAtk) pieces in zone)")
        } else if !wCas {
            flags.append("White king has not castled")
        }
        if !bCas && bAtk >= 2 {
            flags.append("Black king is uncastled and under heavy attack (\(bAtk) pieces in zone)")
        } else if !bCas {
            flags.append("Black king has not castled")
        }

        if let pw = result.passed_white, pw > 0 {
            flags.append("White has \(pw) passed pawn\(pw > 1 ? "s" : "")")
        }
        if let pb = result.passed_black, pb > 0 {
            flags.append("Black has \(pb) passed pawn\(pb > 1 ? "s" : "")")
        }
        if let iw = result.isolated_white, iw >= 2 {
            flags.append("White has \(iw) isolated pawns (structural weakness)")
        }
        if let ib = result.isolated_black, ib >= 2 {
            flags.append("Black has \(ib) isolated pawns (structural weakness)")
        }

        let mat = result.material_balance ?? 0
        if abs(mat) >= 3 {
            flags.append("\(mat > 0 ? "White" : "Black") is up \(abs(mat)) pawn equivalents in material")
        }

        // ── PV in algebraic (strip raw UCI for the LLM) ───────────────────
        // Keep as UCI — the LLM handles "e2→e4" style after uci() in the prompt.
        let bestLine = Array((result.pv ?? []).prefix(4))

        // ── Slow mode detection ───────────────────────────────────────────
        // Fire slow mode for: blunders, mirage moves, sacrifices (material loss
        // that the engine still considers roughly equal or better).
        let isBlunder    = (cpLoss ?? 0) > 150
        let isMirage     = depthProfile == "mirage"
        let isSacrifice  = (cpLoss ?? 0) > 200 && (normScore ?? 0) > -50
        let isSlowMode   = isBlunder || isMirage || isSacrifice

        return ChessCoachingRequest(
            movePlayed:    lastUCI,
            side:          side,
            moveNotation:  movePrefix,
            classification: classification,
            cpLoss:        cpLoss,
            evalAfter:     evalAfter,
            winPctWhite:   result.wdl.map { Int(($0.white * 100).rounded()) },
            winPctDraw:    result.wdl.map { Int(($0.draw  * 100).rounded()) },
            winPctBlack:   result.wdl.map { Int(($0.black * 100).rounded()) },
            gamePhase:     result.game_phase,
            materialDelta: mat,
            bestMove:      bestMoveUCI,
            bestMoveEval:  bestMoveEval,
            bestLine:      bestLine,
            depthProfile:  depthProfile,
            tacticalFlags: flags,
            isSlowMode:    isSlowMode
        )
    }

    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from  = String(uci.prefix(2))
        let to    = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}
