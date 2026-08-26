import SwiftUI

/// Main mixer window: a console-style row of channel strips (inputs, then
/// the main output) aligned against a left-hand row-label gutter.
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

            // Engine status + global settings
            HStack {
                Circle()
                    .fill(viewModel.mixerEngine.isRunning ? MixerTheme.engineRunning : MixerTheme.engineStopped)
                    .frame(width: 8, height: 8)
                Text(viewModel.mixerEngine.isRunning ? "Engine Running" : "Engine Stopped")
                    .font(.caption)
                    .foregroundStyle(MixerTheme.textSecondary)
                Spacer()
                Toggle("Low latency", isOn: Binding(
                    get: { viewModel.lowLatencyModeEnabled },
                    set: { viewModel.setLowLatencyModeEnabled($0) }
                ))
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(MixerTheme.textLabel)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Console: row-label gutter + one strip per input + the main output strip.
            HStack(alignment: .top, spacing: 8) {
                ConsoleGutterView()
                ForEach(viewModel.inputStrips) { strip in
                    ConsoleStripView(kind: .input(strip))
                }
                ConsoleStripView(kind: .main(viewModel.mainOutput))
            }
            .padding(16)
        }
        .background(MixerTheme.consoleBg)
        .frame(minWidth: 440, minHeight: 560)
    }
}
