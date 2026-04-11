import SwiftUI

/// Main mixer window with input strips on the left and output strip on the right.
struct MixerWindow: View {
    @Environment(MixerViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = viewModel.mixerEngine.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.mixerEngine.lastError = nil
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.red.opacity(0.3))
            }

            // Engine status
            HStack {
                Circle()
                    .fill(viewModel.mixerEngine.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.mixerEngine.isRunning ? "Engine Running" : "Engine Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

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
        }
        .background(Color(nsColor: .init(white: 0.12, alpha: 1.0)))
        .frame(minWidth: 650, minHeight: 400)
    }
}
