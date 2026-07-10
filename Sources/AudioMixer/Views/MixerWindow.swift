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
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.mixerEngine.lastError = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                }
                .padding(8)
                .background(MixerTheme.errorBannerBg)
            }

            // Engine status
            HStack {
                Circle()
                    .fill(viewModel.mixerEngine.isRunning ? MixerTheme.engineRunning : MixerTheme.engineStopped)
                    .frame(width: 8, height: 8)
                Text(viewModel.mixerEngine.isRunning ? "Engine Running" : "Engine Stopped")
                    .font(.caption)
                    .foregroundStyle(MixerTheme.textSecondary)
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
        .background(MixerTheme.windowBg)
        .frame(minWidth: 650, minHeight: 400)
    }
}
