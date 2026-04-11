import SwiftUI

/// Main mixer window with input strips on the left and output strip on the right.
struct MixerWindow: View {
    @Environment(MixerViewModel.self) private var viewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Input strips
            VStack(spacing: 12) {
                ForEach(viewModel.inputStrips) { strip in
                    InputStripView(strip: strip)
                }
            }

            // Output strip
            VStack(spacing: 12) {
                OutputStripView(strip: viewModel.mainOutput)
                Spacer()
            }
        }
        .padding(16)
        .background(Color(nsColor: .init(white: 0.12, alpha: 1.0)))
        .frame(minWidth: 650, minHeight: 400)
    }
}
