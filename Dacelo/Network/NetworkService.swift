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

    // Exposed so Lc0Robot can build the URL on its background thread
    var webSocketURL: URL? {
        URL(string: "ws://\(serverHost):\(serverPort)")
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!

    private struct PendingRequest {
        let id: String
        let expectedTypes: Set<String>
        let continuation: CheckedContinuation<Data, Error>
    }
    private var pendingRequests: [PendingRequest] = []

    // Callback-based pending requests for use from non-async contexts (e.g. Lc0Robot)
    private struct CallbackRequest {
        let expectedTypes: Set<String>
        let completion: (Data) -> Void
    }
    private var callbackRequests: [CallbackRequest] = []

    private var pingTimer: Timer?

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }
        guard let url = webSocketURL else {
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
        callbackRequests.removeAll()
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
                    self.callbackRequests.removeAll()
                    waiting.forEach { $0.continuation.resume(throwing: error) }
                }
            }
        }
    }

    private func routeIncomingMessage(_ data: Data) {
        guard let partial = try? JSONDecoder().decode(TypeOnlyResponse.self, from: data) else {
            return
        }

        let responseType = partial.type
        guard responseType != "pong", responseType != "info" else { return }

        // Route to async continuation requests first
        if let idx = pendingRequests.firstIndex(where: {
            $0.expectedTypes.contains(responseType) || responseType == "error"
        }) {
            let pending = pendingRequests.remove(at: idx)
            pending.continuation.resume(returning: data)
            return
        }

        // Route to callback-based requests (used by Lc0Robot from background thread)
        if let idx = callbackRequests.firstIndex(where: {
            $0.expectedTypes.contains(responseType) || responseType == "error"
        }) {
            let pending = callbackRequests.remove(at: idx)
            pending.completion(data)
            return
        }
    }

    // MARK: - Keep-alive

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                try? await self.sendJSON(["cmd": "ping"])
            }
        }
    }

    // MARK: - Public async API (for AnalysisService)

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

    // MARK: - Public callback API (for Lc0Robot background thread)
    //
    // Called from a background thread (the library's detached thread).
    // Registers a callback completion handler, sends the JSON, and returns
    // immediately. The completion fires when the response arrives on main.
    // The caller blocks on a DispatchSemaphore until completion fires.

    func sendEngineMove(jsonString: String, completion: @escaping (EngineMovesResponse) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isConnected else {
                print("[NetworkService] sendEngineMove called while not connected")
                completion(EngineMovesResponse(
                    type: "error", move: nil, from: nil, to: nil,
                    promotion: nil, score_cp: nil, score_mate: nil,
                    pv: nil, message: "Not connected"
                ))
                return
            }

            // Register the callback before sending to avoid a race
            let callbackRequest = CallbackRequest(
                expectedTypes: ["engine_move"]
            ) { data in
                guard let result = try? JSONDecoder().decode(EngineMovesResponse.self, from: data) else {
                    completion(EngineMovesResponse(
                        type: "error", move: nil, from: nil, to: nil,
                        promotion: nil, score_cp: nil, score_mate: nil,
                        pv: nil, message: "Decode failed"
                    ))
                    return
                }
                completion(result)
            }
            self.callbackRequests.append(callbackRequest)

            // Send the raw JSON string directly
            self.webSocketTask?.send(.string(jsonString)) { error in
                if let error {
                    print("[NetworkService] WebSocket send error: \(error)")
                }
            }
        }
    }

    // MARK: - Private async helpers

    private func request(_ dict: [String: Any], expectedTypes: Set<String>) async throws -> Data {
        try await sendJSON(dict)

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
