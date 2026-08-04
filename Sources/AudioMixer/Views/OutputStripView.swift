import SwiftUI

/// Output channel strip with device picker and level meters.
struct OutputStripView: View {
    @Environment(MixerViewModel.self) private var viewModel
    @Bindable var strip: OutputStripViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                Text(strip.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MixerTheme.textLabel)

                Toggle("Monitoring", isOn: Binding(
                    get: { viewModel.monitoringEnabled },
                    set: { viewModel.setMonitoringEnabled($0) }
                ))
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(MixerTheme.textLabel)

                // Device picker
                Picker("", selection: Binding(
                    get: { strip.selectedDevice },
                    set: { viewModel.selectMonitorDevice($0) }
                )) {
                    Text("None").tag(AudioDevice.none)
                    ForEach(viewModel.selectableMonitorDevices) { device in
                        Text(device.name).tag(device)
                    }
                }
                .labelsHidden()
                .disabled(!viewModel.monitoringEnabled)

                Toggle("Low latency", isOn: Binding(
                    get: { viewModel.lowLatencyModeEnabled },
                    set: { viewModel.setLowLatencyModeEnabled($0) }
                ))
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(MixerTheme.textLabel)

                // Level meters
                HStack(spacing: 4) {
                    Text("L")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MixerTheme.textMeterLabel)
                        .frame(width: 12)
                    VUMeterView(level: strip.levelLeft)
                }
                HStack(spacing: 4) {
                    Text("R")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MixerTheme.textMeterLabel)
                        .frame(width: 12)
                    VUMeterView(level: strip.levelRight)
                }
            }
            .padding(8)
        }
        .backgroundStyle(MixerTheme.stripBg)
    }
}
