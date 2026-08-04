import SwiftUI

/// A single input channel strip with device picker, channel selectors, volume, and routing.
struct InputStripView: View {
    @Environment(MixerViewModel.self) private var viewModel
    @Bindable var strip: InputStripViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                Text(strip.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MixerTheme.textLabel)

                // Device picker
                Picker("", selection: Binding(
                    get: { strip.selectedDevice },
                    set: { viewModel.selectInputDevice($0, forStrip: strip) }
                )) {
                    Text("N/A").tag(AudioDevice.none)
                    ForEach(viewModel.selectableInputDevices) { device in
                        Text(device.name).tag(device)
                    }
                }
                .labelsHidden()

                // Channel selectors
                if strip.selectedDevice.id != AudioDevice.none.id {
                    HStack(spacing: 12) {
                        channelPicker(label: "L", selection: Binding(
                            get: { strip.leftChannelIndex },
                            set: { viewModel.setLeftChannel($0, forStrip: strip) }
                        ))
                        channelPicker(label: "R", selection: Binding(
                            get: { strip.rightChannelIndex },
                            set: { viewModel.setRightChannel($0, forStrip: strip) }
                        ))
                    }
                }

                // Level meters
                HStack(spacing: 4) {
                    Text("L")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MixerTheme.textMeterLabel)
                        .frame(width: 12)
                    VUMeterView(level: strip.levelLeft)
                    Text("R")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MixerTheme.textMeterLabel)
                        .frame(width: 12)
                    VUMeterView(level: strip.levelRight)
                }

                // Volume slider with +6dB toggle
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { strip.volume },
                            set: { viewModel.updateVolume($0, forStrip: strip) }
                        ),
                        in: 0...1
                    )
                    Button(action: { viewModel.toggleBoost(forStrip: strip) }) {
                        Text("+6dB")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(strip.boostEnabled ? MixerTheme.boostActive : MixerTheme.boostInactive)
                            .foregroundStyle(strip.boostEnabled ? MixerTheme.routeActiveFg : MixerTheme.routeInactiveFg)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }

                // Routing buttons
                HStack(spacing: 6) {
                    routeButton(label: "Main", active: strip.routeToMain) {
                        viewModel.toggleRouteToMain(forStrip: strip)
                    }
                    // Placeholders for future Aux outputs
                    auxButton(label: "Aux 1")
                    auxButton(label: "Aux 2")
                    auxButton(label: "Aux 3")
                }
            }
            .padding(8)
        }
        .backgroundStyle(MixerTheme.stripBg)
    }

    // MARK: - Subviews

    private func channelPicker(label: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(MixerTheme.textLabel)
            Picker("", selection: selection) {
                ForEach(strip.availableChannels) { ch in
                    Text(ch.label).tag(ch.index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 80)
        }
    }

    private func routeButton(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(active ? MixerTheme.routeActiveMain : MixerTheme.routeInactive)
                .foregroundStyle(active ? MixerTheme.routeActiveFg : MixerTheme.routeInactiveFg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func auxButton(label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(MixerTheme.routeInactive.opacity(0.5))
            .foregroundStyle(MixerTheme.routeDisabledFg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

