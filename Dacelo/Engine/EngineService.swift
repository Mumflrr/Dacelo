// EngineService.swift
// Dacelo
// Engine/

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
    // Created on MainActor by AppStore and passed in — avoids calling
    // a @MainActor initialiser from inside the actor's own init.
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

    func analyse(fen: String, movetime: Int = 2000) async throws -> AnalysisResponse {
        let data = try await request(
            ["cmd": "analyse", "fen": fen, "movetime": movetime],
            expectedTypes: ["analysis"],
            timeout: Double(movetime) / 1000.0 + 15.0
        )
        let result = try decode(AnalysisResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    func engineMove(fen: String, movetime: Int = 3000) async throws -> EngineMoveResponse {
        let data = try await request(
            ["cmd": "engine_move", "fen": fen, "movetime": movetime],
            expectedTypes: ["engine_move"],
            timeout: Double(movetime) / 1000.0 + 15.0
        )
        let result = try decode(EngineMoveResponse.self, from: data)
        if result.type == "error" { throw EngineError.serverError(result.message ?? "unknown") }
        return result
    }

    func newGame() async {
        try? await sendJSON(["cmd": "new_game"])
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
        guard type != "pong", type != "info" else { return }

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
    // nonisolated(unsafe) lets us write to the MainActor object from the
    // actor without a Task hop — safe here because writes are always
    // dispatched to MainActor via DispatchQueue.main.async.

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
