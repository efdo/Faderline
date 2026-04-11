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
                    .fill(Color(nsColor: .init(white: 0.08, alpha: 1.0)))

                // Active level bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelGradient)
                    .frame(width: geometry.size.width * displayLevel)
            }
        }
        .frame(height: 6)
        .onChange(of: level) { _, newValue in
            withAnimation(.linear(duration: 0.05)) {
                displayLevel = CGFloat(newValue)
            }
        }
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}


