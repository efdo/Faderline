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
                    .frame(width: geometry.size.width * displayLevel)
            }
        }
        .frame(height: 10)
        .onChange(of: level) { _, newValue in
            withAnimation(.linear(duration: 0.1)) {
                displayLevel = CGFloat(newValue)
            }
        }
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}


