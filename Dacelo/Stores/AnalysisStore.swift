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
import Chess

@MainActor
final class AnalysisStore: ObservableObject {

    // MARK: - Published State

    @Published var moveCritiques:          [MoveCritique]              = []
    @Published var lastFeedback:           String                      = ""
    @Published var bestMoveArrow:          (from: String, to: String)? = nil
    @Published var isRequestingHint:       Bool                        = false
    @Published var isAnalysing:            Bool                        = false
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

    var canGoBack:    Bool { !moveCritiques.isEmpty && (selectedCritiqueIndex ?? moveCritiques.count - 1) > 0 }
    var canGoForward: Bool { selectedCritiqueIndex != nil && selectedCritiqueIndex! < moveCritiques.count - 1 }

    func goBack() {
        guard !moveCritiques.isEmpty else { return }
        let current = selectedCritiqueIndex ?? (moveCritiques.count - 1)
        selectedCritiqueIndex = max(0, current - 1)
    }
    func goForward() {
        guard let idx = selectedCritiqueIndex else { return }
        let next = idx + 1
        selectedCritiqueIndex = next >= moveCritiques.count ? nil : next
    }

    // MARK: - Private

    private let engine:       EngineService
    private weak var gameStore:    GameStore?
    private weak var appSettings:  AppSettings?
    private var cancellables: Set<AnyCancellable> = []

    private var prevEval:  Int? = nil
    private var moveCount: Int  = 0
    private var tail: Task<Void, Never>?

    // MARK: - Init

    init(engine: EngineService) {
        self.engine = engine
    }

    // MARK: - Public API

    func observe(_ gameStore: GameStore, settings: AppSettings? = nil) {
        self.gameStore   = gameStore
        self.appSettings = settings
        cancellables.removeAll()
        clearHistory()

        gameStore.$chessStore
            .flatMap { $0.$game }
            .removeDuplicates { $0.board.FEN == $1.board.FEN }
            .dropFirst()
            .sink { [weak self] game in
                DispatchQueue.main.async {
                    self?.handlePositionChange(game)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Hint

    func requestHint(count: Int = 1) {
        guard let fen = gameStore?.currentFEN, !fen.isEmpty else { return }
        guard !isRequestingHint else { return }
        isRequestingHint = true
        Task {
            do {
                let result = try await engine.analyse(fen: fen, movetime: 1500)
                if let from = result.from, let to = result.to,
                   !from.isEmpty, !to.isEmpty {
                    bestMoveArrow = (from: from, to: to)
                }
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

    /// Fill any missing narratives — call on entering review mode to catch
    /// moves where the LLM was offline or failed during play.
    func fillMissingNarratives() {
        let pairs = moveCritiques.compactMap { critique -> (UUID, LLMAnalysisContext)? in
            guard let ctx = llmContexts[critique.id] else { return nil }
            return (critique.id, ctx)
        }
        LLMHookService.shared.fillMissingNarratives(
            critiques: pairs.map { (id: $0.0, context: $0.1) }
        )
    }

    func clearLivePanel() {
        lastFeedback           = ""
        bestMoveArrow          = nil
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

    private func handlePositionChange(_ game: Chess.Game) {
        let fen = game.board.FEN
        guard !fen.hasPrefix("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR") else { return }

        bestMoveArrow = nil

        let fenParts      = fen.split(separator: " ").map(String.init)
        let activeColor   = fenParts.count > 1 ? fenParts[1] : "w"
        let sideJustMoved = activeColor == "w" ? "black" : "white"

        let fullMove   = Int(fenParts.count > 5 ? fenParts[5] : "1") ?? 1
        let displayNum = sideJustMoved == "white" ? fullMove : max(1, fullMove - 1)
        let movePrefix = sideJustMoved == "white" ? "\(displayNum)." : "\(displayNum)..."

        let lastMove: Chess.Move? = {
            guard let lastTurn = game.board.turns.last else { return nil }
            return lastTurn.black ?? lastTurn.white
        }()

        let lastUCI: String = {
            guard let move = lastMove,
                  move.start.isBoardPosition,
                  move.end.isBoardPosition else { return "" }
            let from = move.start.FEN
            let to   = move.end.FEN
            var uci  = from + to
            if case .promotion(let piece) = move.sideEffect {
                switch piece {
                case .queen:  uci += "q"
                case .rook:   uci += "r"
                case .bishop: uci += "b"
                case .knight: uci += "n"
                default:      break
                }
            }
            return uci
        }()

        let pieceType: String = {
            guard let move = lastMove, move.end.isBoardPosition else { return "p" }
            let destPiece = game.board.squares[move.end].piece
            switch destPiece?.pieceType {
            case .knight: return "n"
            case .bishop: return "b"
            case .rook:   return "r"
            case .queen:  return "q"
            case .king:   return "k"
            default:      return "p"
            }
        }()

        moveCount += 1
        let capturedMoveCount  = moveCount
        let capturedPrevEval   = prevEval
        let capturedPieceType  = pieceType
        let isAnalysisMode     = gameStore?.gameMode == .analysisOnly

        // Capture the NNUE engine name now (on MainActor) before entering the Task.
        // In analysis mode the server runs this engine concurrently with the primary
        // eval engine and merges the NNUE breakdown into the response.
        // In regular play mode this is "" — EngineService won't send nnue_engine at all.
        let capturedNNUEEngine = isAnalysisMode ? (appSettings?.nnueEngine ?? "stockfish") : ""

        enqueue {
            await self.runMoveAnalysis(
                fen:            fen,
                side:           sideJustMoved,
                movePrefix:     movePrefix,
                lastUCI:        lastUCI,
                pieceType:      capturedPieceType,
                moveNumber:     capturedMoveCount,
                prevEval:       capturedPrevEval,
                isAnalysisMode: isAnalysisMode,
                nnueEngine:     capturedNNUEEngine
            )
        }
    }

    // MARK: - Analysis

    private func runMoveAnalysis(
        fen:            String,
        side:           String,
        movePrefix:     String,
        lastUCI:        String,
        pieceType:      String,
        moveNumber:     Int,
        prevEval:       Int?,
        isAnalysisMode: Bool,
        nnueEngine:     String
    ) async {
        isAnalysing = true
        defer { isAnalysing = false }

        do {
            let result = try await engine.analyse(
                fen:            fen,
                movetime:       appSettings?.evalTimeMs     ?? 2000,
                evalEngine:     appSettings?.evalEngine     ?? "stockfish",
                bestMoveEngine: appSettings?.bestMoveEngine ?? "lc0",
                nnueEngine:     nnueEngine,
                deep:           isAnalysisMode
            )

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
                suggestedLine:   result.pv ?? []
            )

            moveCritiques.append(critique)

            self.prevEval               = normScore
            self.scoreCP                = normScore
            // FIX: was never set — now populated from the raw engine score
            self.engineScoreCP          = result.score_cp
            self.wdl                    = result.wdl
            self.materialBalance        = result.material_balance
            self.mobilityWhite          = result.mobility_white
            self.mobilityBlack          = result.mobility_black
            self.depth                  = result.depth
            self.nodes                  = result.nodes
            // FIX: was result.deep_score_cp — field didn't exist on AnalysisResponse
            // → compile error. Now defined in EngineModels.swift.
            self.deepScoreCP            = result.deep_score_cp
            self.nnue                   = result.nnue
            self.lastFeedback           = result.feedback ?? ""
            self.currentCharacteristics = result.characteristics
            self.currentPV              = result.pv ?? []
            self.gamePhase              = result.game_phase
            // Pawn structure and king safety only populated in analysis mode
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

            // Build LLM context for every move in analysis mode.
            // Do NOT fire the LLM call here — store the context and fire lazily
            // when the user navigates to this move in post-game review.
            // This avoids LLM latency during analysis and keeps responses
            // tied to the specific move the user is looking at.
            if isAnalysisMode {
                let nnueTermCtx: (String) -> NNUETermContext? = { key in
                    guard let term = result.nnue?[key] else { return nil }
                    return NNUETermContext(white: term.white, black: term.black, total: term.total)
                }
                let ctx = LLMAnalysisContext(
                    fen:                fen,
                    movePlayed:         lastUCI,
                    side:               side,
                    moveNotation:       movePrefix,
                    wdl:                result.wdl.map {
                        WDLContext(white: $0.white, draw: $0.draw, black: $0.black)
                    },
                    scoreCP:            normScore,
                    pvLine:             result.pv ?? [],
                    materialBalance:    result.material_balance ?? 0,
                    mobilityWhite:      result.mobility_white ?? 0,
                    mobilityBlack:      result.mobility_black ?? 0,
                    moveClassification: classification.quality.rawValue,
                    cpLoss:             cpLoss,
                    positionType:       result.characteristics?.position_type      ?? "Equal",
                    precisionRequired:  result.characteristics?.precision_required ?? "Low",
                    evalStability:      result.characteristics?.eval_stability      ?? "Stable",
                    lineType:           result.characteristics?.line_type           ?? "Quiet",
                    alternatives:       alternatives.map {
                        LLMAlternative(move: $0.move, scoreCP: $0.scoreCP)
                    },
                    depth:              result.depth,
                    nodes:              result.nodes,
                    gamePhase:          result.game_phase,
                    pawnStructure:      result.pawn_structure,
                    passedWhite:        result.passed_white,
                    passedBlack:        result.passed_black,
                    isolatedWhite:      result.isolated_white,
                    isolatedBlack:      result.isolated_black,
                    kingAttackersWhite: result.king_attackers_white,
                    kingAttackersBlack: result.king_attackers_black,
                    kingCastledWhite:   result.king_castled_white,
                    kingCastledBlack:   result.king_castled_black,
                    nnueKingSafety:     nnueTermCtx("king_safety"),
                    nnueMobility:       nnueTermCtx("mobility"),
                    nnueThreats:        nnueTermCtx("threats"),
                    nnuePassedPawns:    nnueTermCtx("passed_pawns")
                )
                llmContexts[critique.id] = ctx
                // Fire immediately — narrative is stored silently during play
                // and only displayed when the user enters review mode.
                LLMHookService.shared.requestNarrative(for: critique.id, context: ctx)
            }

        } catch {
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

    private func formatUCI(_ uci: String) -> String {
        guard uci.count >= 4 else { return uci }
        let from  = String(uci.prefix(2))
        let to    = String(uci.dropFirst(2).prefix(2))
        let promo = uci.count > 4 ? "=\(uci.suffix(1).uppercased())" : ""
        return "\(from)→\(to)\(promo)"
    }
}
