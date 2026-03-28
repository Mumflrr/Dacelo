// EngineService.swift
// Dacelo
// Engine/
//
// WebSocket client for the chess_server.py bridge.
// Implemented as a Swift actor — all state mutations are serialised.
//
// Connection lifecycle:
//   configure(host:port:) → connect() → [ping loop] → disconnect()
//
// Request/response model:
//   Each public method sends a JSON command and awaits a matching response
//   type via a CheckedContinuation queue. A timeout race task cancels the
//   continuation if the server doesn't respond in time.
//
// Engine routing (all resolved server-side):
//   analyse(evalEngine:bestMoveEngine:nnueEngine:deep:)
//     evalEngine      — scores, WDL, alternatives, characteristics
//     bestMoveEngine  — generates the actual move (may differ from evalEngine)
//     nnueEngine      — concurrent Stockfish run in analysis mode for NNUE terms
//   engineMove(bestMoveEngine:)
//     Used by UCIRobot — returns from/to/promotion for the Chess library
//
// Engine discovery:
//   queryEngines() sends {"cmd":"engines"} and returns the server's registered
//   engine name list. Called automatically on connect; result stored in
//   AppSettings.availableEngines for live picker UI.

import Foundation

// MARK: - Connection State (lives on MainActor, observed by UI)

@MainActor
final class EngineConnectionState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var lastError: String? = nil
}

// MARK: - EngineService

actor EngineService: NSObject {

    // MARK: - Public
    let state: EngineConnectionState

    // MARK: - Private
    private var host: String
    private var port: Int

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var pingTask: Task<Void, Never>?

    private struct Pending {
        let expectedTypes: Set<String>
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pending: [Pending] = []

    // MARK: - Init

    init(host: String, port: Int, state: EngineConnectionState) {
        self.host  = host
        self.port  = port
        self.state = state
        super.init()
        urlSession = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - Configuration

    func configure(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    // MARK: - Connection

    func connect() {
        guard let url = URL(string: "ws://\(host):\(port)") else {
            setError("Invalid URL: ws://\(host):\(port)")
            return
        }
        clearError()
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        startReceiving()
        startPing()
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        setConnected(false)
        flushPending(throwing: EngineError.notConnected)
    }

    // MARK: - Public API

    /// Analyse a position.
    ///
    /// - Parameters:
    ///   - evalEngine:     Engine name to use for evaluation (default "primary").
    ///   - bestMoveEngine: Engine name to use for best-move generation (default "primary").
    ///                     When different from evalEngine, the server runs both and returns
    ///                     the move engine's score as `deep_score_cp`.
    ///   - nnueEngine:     Engine to run concurrently for NNUE breakdown (analysis mode only).
    ///                     Only used when `deep=true`. Typically "stockfish". Pass nil or ""
    ///                     to skip NNUE analysis. The server runs this engine in parallel with
    ///                     the eval engine and merges its `nnue` field into the response.
    func analyse(
        fen:             String,
        movetime:        Int    = 2000,
        evalEngine:      String = "primary",
        bestMoveEngine:  String = "primary",
        nnueEngine:      String = "",
        deep:            Bool   = false
    ) async throws -> AnalysisResponse {
        var payload: [String: Any] = [
            "cmd":               "analyse",
            "fen":               fen,
            "movetime":          movetime,
            "eval_engine":       evalEngine,
            "best_move_engine":  bestMoveEngine,
            "deep":              deep,
        ]
        // Only send nnue_engine when in deep/analysis mode and a name is specified.
        // The server skips NNUE analysis when this key is absent or empty.
        if deep && !nnueEngine.isEmpty {
            payload["nnue_engine"] = nnueEngine
        }
        let data = try await request(
            payload,
            expectedTypes: ["analysis"],
            timeout: Double(movetime) / 1000.0 + (deep ? 20.0 : 15.0)
        )
        let result = try decode(AnalysisResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    /// Request the engine's best move for a position.
    func engineMove(
        fen:            String,
        movetime:       Int    = 1000,
        bestMoveEngine: String = "primary"
    ) async throws -> EngineMoveResponse {
        let data = try await request(
            [
                "cmd":      "engine_move",
                "fen":      fen,
                "movetime": movetime,
                "engine":   bestMoveEngine,
            ],
            expectedTypes: ["engine_move"],
            timeout: Double(movetime) / 1000.0 + 15.0
        )
        let result = try decode(EngineMoveResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    // MARK: - Pondering

    /// Begin pondering the engine's predicted opponent reply.
    ///
    /// Call this immediately after the robot plays a move, passing the first
    /// move of the engine's PV as `ponderMove`. The engine starts thinking
    /// about the position after that predicted reply — on the opponent's time.
    ///
    /// Fire and forget — no response expected. The engine runs freely until
    /// `ponderhit()` or `stopPonder()` is called.
    func ponder(
        fen:         String,
        ponderMove:  String,
        engine:      String = "primary"
    ) async {
        try? await sendJSON([
            "cmd":          "ponder",
            "fen":          fen,
            "ponder_move":  ponderMove,
            "engine":       engine,
        ])
        // Response is {"type":"ok"} — consumed by route() and discarded
    }

    /// Opponent played the predicted move — convert ponder to real search.
    ///
    /// The engine immediately transitions from ponder mode, keeping all
    /// accumulated work. Returns the best move with the same shape as
    /// `engineMove()`.
    func ponderhit(
        movetime:       Int    = 1000,
        bestMoveEngine: String = "primary"
    ) async throws -> EngineMoveResponse {
        let data = try await request(
            [
                "cmd":      "ponderhit",
                "movetime": movetime,
                "engine":   bestMoveEngine,
            ],
            expectedTypes: ["engine_move"],
            timeout: Double(movetime) / 1000.0 + 15.0
        )
        let result = try decode(EngineMoveResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    /// Opponent played a different move than predicted — discard ponder.
    ///
    /// Call this before issuing a fresh `engineMove()` for the actual position.
    /// Fire and forget — the server stops the engine and drains its output.
    func stopPonder(engine: String = "primary") async {
        try? await sendJSON([
            "cmd":    "stop_ponder",
            "engine": engine,
        ])
    }

    func newGame() async {
        try? await sendJSON(["cmd": "new_game"])
    }

    // MARK: - Pondering

    /// Begin pondering the engine's predicted opponent reply.
    /// Fire-and-forget — returns immediately. Server routes ponder output to
    /// a separate queue so it can never contaminate analysis results.
    func ponder(fen: String, ponderMove: String, engine: String = "primary") async {
        try? await sendJSON([
            "cmd":          "ponder",
            "fen":          fen,
            "ponder_move":  ponderMove,
            "engine":       engine,
        ])
        // Response is {"type":"ok"} — swallowed by route() since "ok" is filtered
    }

    /// Opponent played the predicted move — convert accumulated ponder work into
    /// a real search result. Returns same shape as engineMove().
    func ponderhit(
        fen:            String,
        movetime:       Int    = 1000,
        bestMoveEngine: String = "primary"
    ) async throws -> EngineMoveResponse {
        let data = try await request(
            ["cmd": "ponderhit", "fen": fen, "movetime": movetime, "engine": bestMoveEngine],
            expectedTypes: ["engine_move"],
            timeout: Double(movetime) / 1000.0 + 15.0
        )
        let result = try decode(EngineMoveResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    /// Opponent played a different move — discard ponder. Fire-and-forget.
    func stopPonder(engine: String = "primary") async {
        try? await sendJSON(["cmd": "stop_ponder", "engine": engine])
    }

    /// Query the server for the list of registered engine names.
    /// Call once after connecting; the result populates AppSettings.availableEngines
    /// so the UI can show live pickers instead of free-text fields.
    func queryEngines() async -> [String] {
        guard webSocketTask != nil else { return [] }
        do {
            let data = try await request(
                ["cmd": "engines"],
                expectedTypes: ["engines"],
                timeout: 5.0
            )
            let decoded = try? JSONDecoder().decode(EnginesResponse.self, from: data)
            return decoded?.engines ?? []
        } catch {
            return []
        }
    }

    // MARK: - Private: request / response

    private func request(
        _ dict: [String: Any],
        expectedTypes: Set<String>,
        timeout: Double
    ) async throws -> Data {
        guard webSocketTask != nil else { throw EngineError.notConnected }
        try await sendJSON(dict)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    Task { [weak self] in
                        await self?.registerPending(
                            Pending(expectedTypes: expectedTypes, continuation: cont)
                        )
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw EngineError.timeout
            }
            guard let data = try await group.next() else { throw EngineError.timeout }
            group.cancelAll()
            return data
        }
    }

    private func registerPending(_ p: Pending) {
        pending.append(p)
    }

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .failure(let error):
            setConnected(false)
            setError(error.localizedDescription)
            flushPending(throwing: error)

        case .success(let message):
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let d):      data = d
            @unknown default:       data = Data()
            }
            route(data)
            startReceiving()
        }
    }

    private func route(_ data: Data) {
        guard let partial = try? JSONDecoder().decode(TypeOnlyResponse.self, from: data) else { return }
        let type = partial.type
        guard type != "pong", type != "info", type != "ok" else { return }

        if let idx = pending.firstIndex(where: {
            $0.expectedTypes.contains(type) || type == "error"
        }) {
            let p = pending.remove(at: idx)
            p.continuation.resume(returning: data)
        }
    }

    private func flushPending(throwing error: Error) {
        let all = pending
        pending.removeAll()
        all.forEach { $0.continuation.resume(throwing: error) }
    }

    private func sendJSON(_ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await webSocketTask?.send(.string(text))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw EngineError.decodingFailed
        }
        return value
    }

    // MARK: - Keep-alive

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                try? await sendJSON(["cmd": "ping"])
            }
        }
    }

    // MARK: - State helpers

    private func setConnected(_ value: Bool) {
        let s = state
        DispatchQueue.main.async { s.isConnected = value }
    }

    private func setError(_ message: String) {
        let s = state
        DispatchQueue.main.async { s.lastError = message }
    }

    private func clearError() {
        let s = state
        DispatchQueue.main.async { s.lastError = nil }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension EngineService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { [weak self] in await self?.handleOpen() }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { [weak self] in await self?.handleClose() }
    }

    private func handleOpen() {
        setConnected(true)
        clearError()
    }

    private func handleClose() {
        setConnected(false)
    }
}
