// Lc0Player.swift
// Dacelo
//
// Chess.Robot subclass that connects to remote lc0 server.
// Manages its own WebSocket connection independently of NetworkService
// so it can operate safely from Chess.Robot's detached background thread.

import Chess
import Foundation

// MARK: - Lc0Robot

final class Lc0Robot: Chess.Robot {

    // Immutable config — safe to read from any thread
    private let serverHost: String
    private let serverPort: Int
    private let moveTimeMs: Int

    init(side: Chess.Side, serverHost: String, serverPort: Int, moveTimeMs: Int = 3000) {
        self.serverHost  = serverHost
        self.serverPort  = serverPort
        self.moveTimeMs  = moveTimeMs
        super.init(side: side, stopAfterMove: 200)
    }

    // MARK: - Chess.Robot override
    //
    // Called on Chess.Robot's detached background thread. Must return synchronously.
    // We open our own URLSessionWebSocketTask here — entirely thread-safe because
    // URLSession itself is thread-safe and we hold no @MainActor state.

    override func evalutate(board: Chess.Board) -> Chess.Move? {
        let fen = board.FEN
        guard let url = URL(string: "ws://\(serverHost):\(serverPort)") else {
            print("[Lc0Robot] Invalid server URL")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = MoveBox()

        // Each evalutate call gets its own short-lived WebSocket task.
        // URLSession.shared is thread-safe and needs no actor isolation.
        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()

        // Send the engine_move command
        let body: [String: Any] = [
            "cmd": "engine_move",
            "fen": fen,
            "movetime": moveTimeMs
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[Lc0Robot] Failed to encode request")
            return nil
        }

        wsTask.send(.string(jsonString)) { error in
            if let error {
                print("[Lc0Robot] Send error: \(error)")
                semaphore.signal()
            }
        }

        // Wait for the engine_move response, ignoring any info/pong frames
        func receiveNext() {
            wsTask.receive { result in
                switch result {
                case .failure(let error):
                    print("[Lc0Robot] Receive error: \(error)")
                    semaphore.signal()

                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let d):      data = d
                    @unknown default:
                        receiveNext()
                        return
                    }

                    // Decode just the type first
                    guard let partial = try? JSONDecoder().decode(TypeOnly.self, from: data) else {
                        receiveNext()
                        return
                    }

                    // Ignore pong and analysis frames — keep waiting
                    guard partial.type == "engine_move" || partial.type == "error" else {
                        receiveNext()
                        return
                    }

                    guard partial.type == "engine_move",
                          let response = try? JSONDecoder().decode(EngineMovesResponse.self, from: data),
                          let fromStr = response.from,
                          let toStr   = response.to else {
                        print("[Lc0Robot] Bad engine_move response")
                        semaphore.signal()
                        return
                    }

                    print("[Lc0Robot] Playing: \(fromStr) -> \(toStr)")

                    let startPos = Chess.Position.from(rankAndFile: fromStr)
                    let endPos   = Chess.Position.from(rankAndFile: toStr)

                    let sideEffect: Chess.Move.SideEffect
                    if let promoStr = response.promotion,
                       let piece    = self.promotionPieceType(from: promoStr) {
                        sideEffect = .promotion(piece: piece)
                    } else {
                        sideEffect = .notKnown
                    }

                    box.move = Chess.Move(
                        side:       self.side,
                        start:      startPos,
                        end:        endPos,
                        sideEffect: sideEffect
                    )
                    semaphore.signal()
                }
            }
        }

        receiveNext()

        // Block this background thread until we have a move (or failure).
        // Timeout matches movetime + generous overhead.
        let timeoutResult = semaphore.wait(timeout: .now() + .milliseconds(moveTimeMs + 10_000))
        if timeoutResult == .timedOut {
            print("[Lc0Robot] Timed out waiting for engine move")
        }

        wsTask.cancel(with: .goingAway, reason: nil)
        return box.move
    }

    // MARK: - Helpers

    private func promotionPieceType(from uciChar: String) -> Chess.PieceType? {
        switch uciChar.lowercased() {
        case "q": return .queen
        case "r": return .rook
        case "b": return .bishop
        case "n": return .knight
        default:  return nil
        }
    }
}

// MARK: - Private helpers

private final class MoveBox: @unchecked Sendable {
    var move: Chess.Move? = nil
}

private struct TypeOnly: Decodable {
    let type: String
}
