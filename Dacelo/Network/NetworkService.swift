// NetworkService.swift
// LeelaChessApp
//
// WebSocket client connecting to lc0_server.py on your Windows PC via Tailscale.
// Uses URLSessionWebSocketTask with async/await.

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
    let message: String?   // present on error responses
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

    @Published var isConnected: Bool   = false
    @Published var lastError: String?

    var serverHost: String = "your-pc-hostname"
    var serverPort: Int    = 8765

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!

    // Pending one-shot continuations: each outbound request registers one,
    // the receive loop resolves the next one in line.
    private var pending: [CheckedContinuation<Data, Error>] = []

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
        // Fail any pending requests
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume(throwing: Lc0ServerError.notConnected) }
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
                    self.deliver(data)
                    self.startReceiving()      // keep listening
                }
            case .failure(let error):
                Task { @MainActor in
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    // Fail pending
                    let waiting = self.pending
                    self.pending.removeAll()
                    waiting.forEach { $0.resume(throwing: error) }
                }
            }
        }
    }

    private func deliver(_ data: Data) {
        guard !pending.isEmpty else { return }
        let cont = pending.removeFirst()
        cont.resume(returning: data)
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

    // MARK: - Public API

    func analyse(fen: String, movetime: Int = 2000) async throws -> AnalysisResponse {
        guard isConnected else { throw Lc0ServerError.notConnected }
        let data = try await request(["cmd": "analyse", "fen": fen, "movetime": movetime])
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
        let data = try await request(["cmd": "engine_move", "fen": fen, "movetime": movetime])
        guard let result = try? JSONDecoder().decode(EngineMovesResponse.self, from: data) else {
            throw Lc0ServerError.decodingFailed
        }
        if result.type == "error" {
            throw Lc0ServerError.serverError(result.message ?? "unknown error")
        }
        return result
    }

    // MARK: - Private send + wait

    private func request(_ dict: [String: Any]) async throws -> Data {
        try await sendJSON(dict)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Task 1: wait for the server response via continuation
            group.addTask {
                try await withCheckedThrowingContinuation { [weak self] (cont: CheckedContinuation<Data, Error>) in
                    guard let self else {
                        cont.resume(throwing: Lc0ServerError.notConnected)
                        return
                    }
                    // Register the continuation on the MainActor
                    Task { @MainActor [weak self] in
                        self?.pending.append(cont)
                    }
                }
            }
            // Task 2: 15 second timeout
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw Lc0ServerError.timeout
            }

            // Return whichever finishes first
            guard let data = try await group.next() else {
                throw Lc0ServerError.timeout
            }
            group.cancelAll()
            return data
        }
    }

    private func sendJSON(_ dict: [String: Any]) async throws {
        let json  = try JSONSerialization.data(withJSONObject: dict)
        let text  = String(data: json, encoding: .utf8) ?? "{}"
        try await webSocketTask?.send(.string(text))
    }
}

// MARK: - URLSessionWebSocketDelegate

extension NetworkService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.lastError   = nil
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
