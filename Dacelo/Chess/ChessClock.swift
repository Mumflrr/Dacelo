// ChessClock.swift
// Dacelo
//
// Self-contained chess clock. Tracks time for both players independently.
// GameStore owns an optional ChessClock and starts/stops it as turns change.
//
// Time controls:
//   .unlimited       — no clock (default)
//   .fixed(seconds)  — each player gets N seconds total (classic)
//   .increment(seconds, increment) — Fischer: N seconds + I seconds added after each move
//
// Architecture:
//   ChessClock is a plain ObservableObject on @MainActor.
//   A single Timer fires every 0.1s and decrements the active player's time.
//   GameStore calls .switchTurn() after each move and .pause()/.resume() as needed.

import SwiftUI
import Combine

// MARK: - TimeControl

enum TimeControl: Equatable, Codable, Hashable {
    case unlimited
    case fixed(seconds: Int)
    case increment(seconds: Int, increment: Int)

    var isUnlimited: Bool {
        if case .unlimited = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .unlimited:                       return "Unlimited"
        case .fixed(let s):                    return "\(s / 60)min"
        case .increment(let s, let i):         return "\(s / 60)min +\(i)s"
        }
    }

    var initialSeconds: Double {
        switch self {
        case .unlimited:                       return .infinity
        case .fixed(let s):                    return Double(s)
        case .increment(let s, _):             return Double(s)
        }
    }

    var incrementSeconds: Double {
        switch self {
        case .increment(_, let i): return Double(i)
        default:                   return 0
        }
    }

    /// Common presets shown in the picker.
    static let presets: [TimeControl] = [
        .unlimited,
        .fixed(seconds: 60),
        .fixed(seconds: 180),
        .fixed(seconds: 300),
        .increment(seconds: 180, increment: 2),
        .increment(seconds: 600, increment: 5),
        .fixed(seconds: 1800),
    ]
}

// MARK: - ChessClock

@MainActor
final class ChessClock: ObservableObject {

    @Published var whiteTime:  Double = .infinity
    @Published var blackTime:  Double = .infinity
    @Published var activeSide: Side   = .white
    @Published var isRunning:  Bool   = false
    @Published var flagged:    Side?  = nil   // non-nil when a player runs out of time

    private var control:      TimeControl = .unlimited
    private var timer:        AnyCancellable?
    private let tickInterval: Double = 0.1

    // MARK: - Setup

    func configure(control: TimeControl, startingSide: Side = .white) {
        self.control         = control
        self.activeSide      = startingSide
        self.flagged         = nil
        self.isRunning       = false
        self.whiteMoved      = false
        self.blackMoved      = false
        whiteTime = control.initialSeconds
        blackTime = control.initialSeconds
        // Add 30-second grace bonus for the very first move of each side.
        // Stored separately and consumed on first switchTurn per side.
        whiteBonus = control.isUnlimited ? 0 : 30
        blackBonus = control.isUnlimited ? 0 : 30
        timer?.cancel()
        timer = nil
    }

    // Tracks whether each side has made their first move (bonus consumed).
    private var whiteMoved = false
    private var blackMoved = false
    private var whiteBonus: Double = 0
    private var blackBonus: Double = 0

    // MARK: - Controls

    func start() {
        guard case .unlimited = control else {
            startTicking()
            return
        }
        // Unlimited — no ticking needed
    }

    func pause() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    func resume() {
        guard flagged == nil else { return }
        startTicking()
    }

    /// Call after each move is played. Adds increment to the side that just moved,
    /// then switches the active side.
    func switchTurn(movedSide: Side) {
        let inc = control.incrementSeconds
        if movedSide == .white {
            whiteMoved = true
            whiteBonus = 0  // grace period consumed
            whiteTime  = min(whiteTime + inc, control.isUnlimited ? .infinity : whiteTime + inc)
        } else {
            blackMoved = true
            blackBonus = 0
            blackTime  = min(blackTime + inc, control.isUnlimited ? .infinity : blackTime + inc)
        }
        activeSide = movedSide.opposite
    }

    // MARK: - Display helpers

    func timeString(for side: Side) -> String {
        let t = side == .white ? whiteTime : blackTime
        guard t.isFinite else { return "∞" }
        let total = max(0, Int(t))
        let mins  = total / 60
        let secs  = total % 60
        let tenths = max(0, Int((t - Double(total)) * 10))
        if total < 20 {
            return String(format: "%d.%d", secs, tenths)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    var isLowTime: Bool {
        let t = activeSide == .white ? whiteTime : blackTime
        return t.isFinite && t < 10
    }

    // MARK: - Private

    private func startTicking() {
        guard flagged == nil else { return }
        isRunning = true
        timer?.cancel()
        timer = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard isRunning, flagged == nil else { return }
        if activeSide == .white {
            if whiteBonus > 0 {
                whiteBonus -= tickInterval  // drain grace period first
            } else {
                whiteTime -= tickInterval
                if whiteTime <= 0 {
                    whiteTime = 0
                    flagged   = .white
                    pause()
                }
            }
        } else {
            if blackBonus > 0 {
                blackBonus -= tickInterval
            } else {
                blackTime -= tickInterval
                if blackTime <= 0 {
                    blackTime = 0
                    flagged   = .black
                    pause()
                }
            }
        }
    }
}

// MARK: - ClockDisplayView

/// Compact clock display for one player. Shows time in large monospaced digits,
/// turns red when below 10 seconds.
struct ClockDisplayView: View {
    let time:     Double
    let side:     Side
    let isActive: Bool
    let flagged:  Bool

    var body: some View {
        if time.isFinite {
            clockFace(t: max(0, time))
        }
    }

    @ViewBuilder
    private func clockFace(t: Double) -> some View {
        let total  = Int(t)
        let mins   = total / 60
        let secs   = total % 60
        let tenths = Int((t - Double(total)) * 10)
        let isLow  = t < 10

        let display = isLow
            ? String(format: "%d.%d", secs, tenths)
            : String(format: "%d:%02d", mins, secs)

        Text(display)
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundStyle(flagged ? .red : isLow ? .orange : isActive ? .white : .white.opacity(0.45))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? .white.opacity(0.1) : .white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isActive ? (isLow ? Color.orange : Color.white).opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
