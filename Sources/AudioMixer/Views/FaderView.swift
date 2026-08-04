import SwiftUI
import AppKit

/// A vertical, dB-calibrated console fader.
///
/// The cap's travel maps to `db` through `FaderTaper`, so its position always
/// agrees with the scale drawn by `ConsoleScaleView` and with the meter next
/// to it — all three share the same breakpoint table.
struct FaderView: View {
    @Binding var db: Float

    /// Fader position accumulated so far during the current drag, plus the
    /// translation seen at the last `onChanged` call. Movement is applied
    /// **incrementally** (this call's translation minus the last call's)
    /// rather than rescaling the whole gesture's cumulative translation —
    /// otherwise toggling Shift mid-drag would retroactively rescale
    /// movement already applied under the old sensitivity, causing a sudden
    /// jump in live gain instead of a smooth sensitivity change going forward.
    @State private var dragPosition: Float?
    @State private var lastTranslationHeight: CGFloat = 0

    private let capHeight: CGFloat = 14
    private let trackWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let trackHeight = geometry.size.height
            let usableHeight = max(trackHeight - capHeight, 1)
            let position = CGFloat(FaderTaper.position(forDB: db))
            let unityPosition = CGFloat(FaderTaper.position(forDB: 0))
            let capCenterY = trackHeight - capHeight / 2 - position * usableHeight
            let unityY = trackHeight - capHeight / 2 - unityPosition * usableHeight

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: trackWidth / 2)
                    .fill(MixerTheme.faderTrack)
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Unity (0 dB) detent line
                Rectangle()
                    .fill(MixerTheme.faderCapEdge.opacity(0.6))
                    .frame(width: geometry.size.width, height: 1)
                    .position(x: geometry.size.width / 2, y: unityY)

                // Cap
                RoundedRectangle(cornerRadius: 3)
                    .fill(MixerTheme.faderCap)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(MixerTheme.faderCapEdge, lineWidth: 1)
                    )
                    .overlay {
                        Rectangle()
                            .fill(MixerTheme.faderCapEdge)
                            .frame(height: 2)
                    }
                    .frame(width: geometry.size.width, height: capHeight)
                    .position(x: geometry.size.width / 2, y: capCenterY)
            }
            .frame(width: geometry.size.width, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .onEnded { db = 0 }
                    .exclusively(
                        before: DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragPosition == nil {
                                    dragPosition = FaderTaper.position(forDB: db)
                                    lastTranslationHeight = 0
                                }
                                guard let current = dragPosition else { return }
                                let incrementalTranslation = value.translation.height - lastTranslationHeight
                                lastTranslationHeight = value.translation.height
                                let rawDelta = Float(-incrementalTranslation) / Float(usableHeight)
                                // Shift-drag for fine adjustment. Applied only to
                                // this call's incremental movement, not the whole
                                // gesture's cumulative translation (see property doc).
                                let isFine = NSEvent.modifierFlags.contains(.shift)
                                let delta = isFine ? rawDelta * 0.25 : rawDelta
                                let newPosition = min(max(current + delta, 0), 1)
                                dragPosition = newPosition
                                db = FaderTaper.db(forPosition: newPosition)
                            }
                            .onEnded { _ in
                                dragPosition = nil
                                lastTranslationHeight = 0
                            }
                    )
            )
        }
        .frame(minHeight: MixerTheme.Metrics.faderRowMinHeight)
    }
}
