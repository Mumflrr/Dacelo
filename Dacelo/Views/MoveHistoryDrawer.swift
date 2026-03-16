// MoveHistoryDrawer.swift
// Dacelo
//
// Drag architecture — why this works without stutter:
//
// Problem: On macOS, SwiftUI cancels a DragGesture (without calling onEnded)
// the moment the cursor leaves the gesture view's frame. When using @GestureState,
// that cancellation auto-resets the delta to .zero, causing a visible snap-back
// jump every couple of pixels as the drawer moves and the cursor drifts outside
// the shrinking/growing header hit zone.

import SwiftUI

// MARK: - Snap constants

private enum DrawerSnap {
    static let headerHeight:   CGFloat = 56
    static let expandedHeight: CGFloat = 500
    static let low:            CGFloat = 280
    static let hidden:         CGFloat = expandedHeight - headerHeight  // 444
    static let all:            [CGFloat] = [0, low, hidden]

    static func nearest(to value: CGFloat, velocity: CGFloat = 0) -> CGFloat {
        let biased = value + velocity * 0.18
        return all.min(by: { abs($0 - biased) < abs($1 - biased) }) ?? hidden
    }

    static func nextTap(from current: CGFloat) -> CGFloat {
        if current >= hidden - 10 { return low  }
        if current >= low   - 10  { return 0    }
        return hidden
    }
}

// MARK: - MoveHistoryDrawer

struct MoveHistoryDrawer: View {
    let critiques:     [MoveCritique]
    let selectedIndex: Int?
    
    @EnvironmentObject var analysisStore: AnalysisStore

    // Committed snap position — only written on drag end/cancel or tap
    @State private var snapOffset: CGFloat = DrawerSnap.hidden

    // Live drag delta — State so WE control resets, not the gesture system
    @State private var liveDelta: CGFloat = 0

    // Sentinel: true while gesture is physically active.
    // Using @GestureState means SwiftUI sets it back to false automatically
    // on any termination (normal end OR cancel). We watch onChange to commit.
    @GestureState private var isDragging: Bool = false

    // Tracks the drag's start Y in global space so translation is correct
    @State private var dragStartY: CGFloat = 0

    private var currentOffset: CGFloat {
        (snapOffset + liveDelta).clamped(to: 0...DrawerSnap.hidden)
    }

    // MARK: Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            // isDragging sentinel — @GestureState auto-resets on any termination
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if liveDelta == 0 {
                    // Capture start Y on first event so translation is relative
                    dragStartY = value.startLocation.y
                }
                liveDelta = value.location.y - dragStartY
            }
            .onEnded { value in
                commitSnap(translationY: value.translation.height,
                           velocityY: value.predictedEndTranslation.height - value.translation.height)
            }
    }

    private func commitSnap(translationY: CGFloat, velocityY: CGFloat) {
        let landed = (snapOffset + translationY).clamped(to: 0...DrawerSnap.hidden)
        let target = DrawerSnap.nearest(to: landed, velocity: velocityY)
        liveDelta = 0
        snapOffset = target   // animated by the .animation modifier on .offset below
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            drawerHeader
            cardScrollView
        }
        .frame(height: DrawerSnap.expandedHeight)
        .background(
            RoundedCornersShape(tl: 20, tr: 20, bl: 0, br: 0)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.5), radius: 20, y: -4)
        )
        .overlay(
            RoundedCornersShape(tl: 20, tr: 20, bl: 0, br: 0)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .offset(y: currentOffset)
        // Animate snap transitions; suppress animation during live drag so frames
        // are never interpolated. Using value: currentOffset ensures only state-driven
        // changes animate — window moves/resizes don't change currentOffset so they
        // won't produce phantom animations.
        .animation(isDragging ? nil : .spring(response: 0.36, dampingFraction: 0.82),
                   value: currentOffset)
        // When isDragging flips false (gesture ended OR was cancelled by system),
        // commit whatever translation we've accumulated
        .onChange(of: isDragging) { _, dragging in
            guard !dragging, liveDelta != 0 else { return }
            commitSnap(translationY: liveDelta, velocityY: 0)
        }
    }

    // MARK: Header

    private var drawerHeader: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DrawerSnap.headerHeight)
        .contentShape(Rectangle())
        .gesture(drag)
        .onTapGesture {
            snapOffset = DrawerSnap.nextTap(from: snapOffset)
        }
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: Card scroll
    private var cardScrollView: some View {
        ScrollView {
            MoveHistoryList(critiques: critiques)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
        .frame(height: DrawerSnap.expandedHeight - DrawerSnap.headerHeight)
        .scrollDisabled(isDragging)
    }
}

// MARK: - Clamp helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
