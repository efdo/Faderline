import SwiftUI

/// A horizontal VU-style level meter bar.
struct VUMeterView: View {
    let level: Float

    /// Smoothed level for animation.
    @State private var displayLevel: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(MixerTheme.meterTrackBg)

                // Active level bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelGradient)
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: geometry.size.width * displayLevel)
                    }
            }
        }
        .frame(height: 10)
        .onChange(of: level) { _, newValue in
            withAnimation(.linear(duration: 0.1)) {
                displayLevel = scaledDisplayLevel(for: newValue)
            }
        }
        .onAppear {
            displayLevel = scaledDisplayLevel(for: level)
        }
    }

    private func scaledDisplayLevel(for level: Float) -> CGFloat {
        // Apply scaling for sensitivity, then clamp so the meter never overflows.
        let scaledLevel = CGFloat(level) * 3.0
        return min(max(scaledLevel, 0), 1)
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(.systemGreen), location: 0.0),
                .init(color: Color(.systemGreen), location: 0.68),
                .init(color: Color(.systemYellow), location: 0.85),
                .init(color: Color(.systemRed), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
