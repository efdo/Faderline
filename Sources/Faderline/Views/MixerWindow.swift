import SwiftUI

/// Main mixer window: a console-style row of channel strips (inputs, then
/// the main output) aligned against a left-hand row-label gutter.
struct MixerWindow: View {
    @Environment(MixerViewModel.self) private var viewModel

    var body: some View {
        let minimumSize = MixerTheme.Metrics.consoleMinimumSize(inputCount: viewModel.inputStrips.count)

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

            // Console: row-label gutter + one strip per input + the main output strip.
            HStack(alignment: .top, spacing: MixerTheme.Metrics.consoleSpacing) {
                ConsoleGutterView()
                ForEach(viewModel.inputStrips) { strip in
                    ConsoleStripView(kind: .input(strip))
                }
                ConsoleStripView(kind: .main(viewModel.mainOutput))
            }
            .padding(MixerTheme.Metrics.consolePadding)
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MixerTheme.consoleBg)
    }
}
