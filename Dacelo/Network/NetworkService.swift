// NetworkService.swift
// Dacelo
//
// WebSocket client for lc0 server with full MultiPV and characteristics support

import Foundation
import Combine

// MARK: - Response Models

struct AnalysisResponse: Decodable {
    let type: String
    let fen: String?
    let bestmove: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
    let pv: [String]?
    let depth: Int?
    let nodes: Int?
    let feedback: String?
    let message: String?
    let alternatives: [AlternativeMoveResponse]?
    let characteristics: PositionCharacteristics?
}

struct AlternativeMoveResponse: Decodable {
    let rank: Int
    let move: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
}

struct EngineMovesResponse: Decodable {
    let type: String
    let move: String?
    let from: String?
    let to: String?
    let promotion: String?
    let score_cp: Int?
    let score_mate: Int?
    let pv: [String]?
    let message: String?
}

enum Lc0ServerError: LocalizedError {
    case notConnected
    case serverError(String)
    case timeout
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Not connected to lc0 server"
        case .serverError(let m): return "Server error: \(m)"
        case .timeout:            return "Engine timed out"
        case .decodingFailed:     return "Failed to decode server response"
        }
    }
}

// MARK: - NetworkService

@MainActor
final class NetworkService: NSObject, ObservableObject {

    @Published var isConnected: Bool = false
    @Published var lastError: String?

    var serverHost: String = "your-pc-hostname"
    var serverPort: Int = 8765

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!

    // Each pending request gets a unique ID. Only the matching response
    // resolves its continuation — ping/pong and stale responses are ignored.
    private struct PendingRequest {
        let id: String
        let expectedTypes: Set<String>   // e.g. ["analysis"], ["engine_move"]
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pendingRequests: [PendingRequest] = []

    private var pingTimer: Timer?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }
        guard let url = URL(string: "ws://\(serverHost):\(serverPort)") else {
            lastError = "Invalid server URL: ws://\(serverHost):\(serverPort)"
            return
        }
        lastError = nil
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        startReceiving()
        startPingTimer()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        let waiting = pendingRequests
        pendingRequests.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: Lc0ServerError.notConnected) }
    }

    // MARK: - Receive loop

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let d):      data = d
                @unknown default:       data = Data()
                }
                Task { @MainActor in
                    self.routeIncomingMessage(data)
                    self.startReceiving()
                }
            case .failure(let error):
                Task { @MainActor in
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    let waiting = self.pendingRequests
                    self.pendingRequests.removeAll()
                    waiting.forEach { $0.continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Routes an incoming message only to pending requests whose expectedTypes
    /// match the response's "type" field. Pong and unknown types are silently dropped.
    private func routeIncomingMessage(_ data: Data) {
        // Decode just the type field
        guard let partial = try? JSONDecoder().decode(TypeOnlyResponse.self, from: data) else {
            return
        }

        let responseType = partial.type

        // Silently swallow pong and info messages — never deliver to pending
        guard responseType != "pong", responseType != "info" else { return }

        // Find first pending request that accepts this response type
        if let idx = pendingRequests.firstIndex(where: { $0.expectedTypes.contains(responseType)
                                                          || responseType == "error" }) {
            let pending = pendingRequests.remove(at: idx)
            pending.continuation.resume(returning: data)
        }
        // If no match, the message is dropped (e.g. a stale response after timeout)
    }

    // MARK: - Keep-alive

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                // Fire-and-forget: ping does NOT go through the pending queue
                try? await self.sendJSON(["cmd": "ping"])
            }
        }
    }

    // MARK: - Public API

    func analyse(fen: String, movetime: Int = 2000) async throws -> AnalysisResponse {
        guard isConnected else { throw Lc0ServerError.notConnected }
        let data = try await request(
            ["cmd": "analyse", "fen": fen, "movetime": movetime],
            expectedTypes: ["analysis"]
        )
        guard let result = try? JSONDecoder().decode(AnalysisResponse.self, from: data) else {
            throw Lc0ServerError.decodingFailed
        }
        if result.type == "error" {
            throw Lc0ServerError.serverError(result.message ?? "unknown error")
        }
        return result
    }

    func engineMove(fen: String, movetime: Int = 3000) async throws -> EngineMovesResponse {
        guard isConnected else { throw Lc0ServerError.notConnected }
        let data = try await request(
            ["cmd": "engine_move", "fen": fen, "movetime": movetime],
            expectedTypes: ["engine_move"]
        )
        guard let result = try? JSONDecoder().decode(EngineMovesResponse.self, from: data) else {
            throw Lc0ServerError.decodingFailed
        }
        if result.type == "error" {
            throw Lc0ServerError.serverError(result.message ?? "unknown error")
        }
        return result
    }

    // MARK: - Private

    private func request(_ dict: [String: Any], expectedTypes: Set<String>) async throws -> Data {
        try await sendJSON(dict)

        // Use a 20s timeout (longer than movetime) so we don't time out legitimate long thinks
        let timeoutSeconds: Double = 20

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { [weak self] (cont: CheckedContinuation<Data, Error>) in
                    guard let self else {
                        cont.resume(throwing: Lc0ServerError.notConnected)
                        return
                    }
                    let id = UUID().uuidString
                    let pending = PendingRequest(id: id, expectedTypes: expectedTypes, continuation: cont)
                    Task { @MainActor [weak self] in
                        self?.pendingRequests.append(pending)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw Lc0ServerError.timeout
            }

            guard let data = try await group.next() else {
                throw Lc0ServerError.timeout
            }
            group.cancelAll()
            return data
        }
    }

    private func sendJSON(_ dict: [String: Any]) async throws {
        let json = try JSONSerialization.data(withJSONObject: dict)
        let text = String(data: json, encoding: .utf8) ?? "{}"
        try await webSocketTask?.send(.string(text))
    }
}

// MARK: - Private helpers

private struct TypeOnlyResponse: Decodable {
    let type: String
}

// MARK: - URLSessionWebSocketDelegate

extension NetworkService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.lastError = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            self.isConnected = false
        }
    }
}
