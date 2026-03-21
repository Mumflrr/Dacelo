// MacMoveHistoryDrawer.swift
// Dacelo
//
// macOS-specific move history drawer that slides DOWN from below the
// analysis panel header, unlike the iOS version which slides UP from
// the bottom of the screen.
//
// Snap positions (offset from top of drawer's natural position):
//   collapsed  — only the header is visible (offset = 0, just header peeking)
//   low        — shows roughly one move card
//   expanded   — fills to the available height

import SwiftUI

// MARK: - Snap constants

private enum MacDrawerSnap {
    static let headerHeight: CGFloat = 44
    static let cardHeight:   CGFloat = 200  // ~1.5 cards visible at low snap
    static let low:          CGFloat = headerHeight + cardHeight

    static func nearest(to value: CGFloat, max: CGFloat, velocity: CGFloat = 0) -> CGFloat {
        let biased  = value + velocity * 0.15
        let dynamic = [headerHeight, low, max]
        return dynamic.min(by: { abs($0 - biased) < abs($1 - biased) }) ?? headerHeight
    }

    static func nextTap(from current: CGFloat, max: CGFloat) -> CGFloat {
        if current <= headerHeight + 10 { return low }
        if current <= low        + 10  { return max }
        return headerHeight
    }
}

// MARK: - MacMoveHistoryDrawer

struct MacMoveHistoryDrawer: View {
    let critiques:     [MoveCritique]
    let selectedIndex: Int?
    /// Total height available for the drawer (from just below the analysis panel
    /// to the bottom of the right column). Passed in from the layout.
    let availableHeight: CGFloat

    @EnvironmentObject var analysisStore: AnalysisStore

    @State private var snapHeight: CGFloat = MacDrawerSnap.headerHeight
    @GestureState private var isDragging: Bool = false
    @State private var liveDelta: CGFloat = 0
    @State private var dragStartY: CGFloat = 0

    private var maxHeight: CGFloat { max(MacDrawerSnap.low + 40, availableHeight) }

    private var currentHeight: CGFloat {
        (snapHeight + liveDelta).clamped(to: MacDrawerSnap.headerHeight...maxHeight)
    }

    // MARK: - Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if liveDelta == 0 { dragStartY = value.startLocation.y }
                liveDelta = value.location.y - dragStartY
            }
            .onEnded { value in
                commit(translationY: value.translation.height,
                       velocityY: value.predictedEndTranslation.height - value.translation.height)
            }
    }

    private func commit(translationY: CGFloat, velocityY: CGFloat) {
        let landed = (snapHeight + translationY).clamped(to: MacDrawerSnap.headerHeight...maxHeight)
        snapHeight = MacDrawerSnap.nearest(to: landed, max: maxHeight, velocity: velocityY)
        liveDelta  = 0
    }

    // MARK: - Body

    var body: some View {
        // Don't render until we have a valid height from the parent geometry pass
        guard availableHeight > MacDrawerSnap.headerHeight else { return AnyView(EmptyView()) }
        return AnyView(
        VStack(spacing: 0) {
            header
            if currentHeight > MacDrawerSnap.headerHeight + 4 {
                scrollContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(MacDrawerSnap.headerHeight, currentHeight))
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .animation(isDragging ? nil : .spring(response: 0.36, dampingFraction: 0.82),
                   value: currentHeight)
        .onChange(of: isDragging) { _, dragging in
            guard !dragging, liveDelta != 0 else { return }
            commit(translationY: liveDelta, velocityY: 0)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("Move History")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1)
            Spacer()
            if !critiques.isEmpty {
                Text("\(critiques.count) moves")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            // Drag handle
            Image(systemName: currentHeight > MacDrawerSnap.headerHeight + 4
                  ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .frame(height: MacDrawerSnap.headerHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .onTapGesture {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                snapHeight = MacDrawerSnap.nextTap(from: snapHeight, max: maxHeight)
            }
        }
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        let scrollHeight = max(0, currentHeight - MacDrawerSnap.headerHeight)
        return ScrollView {
            MoveHistoryList(critiques: critiques)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(height: scrollHeight)
        .scrollDisabled(isDragging)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
