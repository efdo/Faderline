import SwiftUI

/// Which strip flavor this view renders. Input strips show device/channel/
/// pan/output-assign/solo controls; the main strip shows only what applies
/// to a master bus (device, dB, fader/meter, mute).
enum ConsoleStripKind {
    case input(InputStripViewModel)
    case main(OutputStripViewModel)
}

/// One console strip: a fixed-height-row layout that lines up with
/// `ConsoleGutterView`'s labels. See `ConsoleRow` for the shared row order.
struct ConsoleStripView: View {
    @Environment(MixerViewModel.self) private var viewModel
    let kind: ConsoleStripKind

    /// Non-soloed input strips dim while another strip is soloed. The main
    /// bus never dims — it's the actual summary of what's being heard.
    private var isDimmed: Bool {
        if case .input(let strip) = kind {
            return viewModel.anySolo && !strip.soloed
        }
        return false
    }

    var body: some View {
        VStack(spacing: MixerTheme.Metrics.rowSpacing) {
            row(.device) { deviceRow }
            row(.channels) { channelsRow }
            row(.output) { outputRow }
            row(.pan) { panRow }
            row(.dbValue) { dbRow }
            row(.faderAndMeter) { faderMeterRow }
            row(.muteSolo) { muteSoloRow }
            row(.namePlate) { namePlateRow }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(width: MixerTheme.Metrics.stripWidth)
        .background(isDimmed ? MixerTheme.stripDimmed : MixerTheme.stripBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Wraps row content at a fixed, shared height so it lines up with
    /// `ConsoleGutterView`'s labels row-for-row.
    private func row<Content: View>(_ rowType: ConsoleRow, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: rowType.height, alignment: rowType == .faderAndMeter ? .top : .center)
    }

    // MARK: - Device

    @ViewBuilder
    private var deviceRow: some View {
        switch kind {
        case .input(let strip):
            Picker("", selection: Binding(
                get: { strip.selectedDevice },
                set: { viewModel.selectInputDevice($0, forStrip: strip) }
            )) {
                Text("N/A").tag(AudioDevice.none)
                ForEach(viewModel.deviceManager.inputDevices) { device in
                    Text(device.name).tag(device)
                }
            }
            .labelsHidden()
            .font(.system(size: 9))
            .lineLimit(1)
        case .main(let output):
            Picker("", selection: Binding(
                get: { output.selectedDevice },
                set: { viewModel.selectOutputDevice($0) }
            )) {
                Text("N/A").tag(AudioDevice.none)
                ForEach(viewModel.deviceManager.outputDevices) { device in
                    Text(device.name).tag(device)
                }
            }
            .labelsHidden()
            .font(.system(size: 9))
            .lineLimit(1)
        }
    }

    // MARK: - Channels

    @ViewBuilder
    private var channelsRow: some View {
        switch kind {
        case .input(let strip):
            if strip.selectedDevice.id != AudioDevice.none.id {
                Picker("", selection: Binding(
                    get: { strip.channelMode },
                    set: { viewModel.setChannelMode($0, forStrip: strip) }
                )) {
                    ForEach(strip.availableChannelModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .font(.system(size: 8))
                .lineLimit(1)
            } else {
                placeholderDash
            }
        case .main:
            placeholderDash
        }
    }

    // MARK: - Output assign ("Main")

    @ViewBuilder
    private var outputRow: some View {
        switch kind {
        case .input(let strip):
            Button {
                viewModel.toggleRouteToMain(forStrip: strip)
            } label: {
                Text("Main")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(strip.routeToMain ? MixerTheme.assignActive : MixerTheme.assignInactive)
                    .foregroundStyle(strip.routeToMain ? MixerTheme.assignActiveFg : MixerTheme.assignInactiveFg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        case .main:
            placeholderDash
        }
    }

    // MARK: - Pan

    @ViewBuilder
    private var panRow: some View {
        switch kind {
        case .input(let strip):
            PanKnobView(pan: Binding(
                get: { strip.pan },
                set: { viewModel.setPan($0, forStrip: strip) }
            ))
            .frame(width: 28, height: 28)
        case .main:
            placeholderDash
        }
    }

    // MARK: - dB field

    @ViewBuilder
    private var dbRow: some View {
        switch kind {
        case .input(let strip):
            DBField(value: strip.gainDB) { viewModel.setGainDB($0, forStrip: strip) }
        case .main(let output):
            DBField(value: output.gainDB) { viewModel.setOutputGainDB($0) }
        }
    }

    // MARK: - Fader + scale + meter

    private var faderMeterRow: some View {
        HStack(spacing: 4) {
            switch kind {
            case .input(let strip):
                FaderView(db: Binding(
                    get: { strip.gainDB },
                    set: { viewModel.setGainDB($0, forStrip: strip) }
                ))
                ConsoleScaleView()
                ChannelMeterView(
                    levelLeft: strip.levelLeft,
                    levelRight: strip.levelRight,
                    peakLeft: strip.peakLeft,
                    peakRight: strip.peakRight,
                    clipped: strip.clipped,
                    onResetClip: { viewModel.resetClip(forStrip: strip) }
                )
            case .main(let output):
                FaderView(db: Binding(
                    get: { output.gainDB },
                    set: { viewModel.setOutputGainDB($0) }
                ))
                ConsoleScaleView()
                ChannelMeterView(
                    levelLeft: output.levelLeft,
                    levelRight: output.levelRight,
                    peakLeft: output.peakLeft,
                    peakRight: output.peakRight,
                    clipped: output.clipped,
                    onResetClip: { viewModel.resetOutputClip() }
                )
            }
        }
    }

    // MARK: - Mute / Solo

    @ViewBuilder
    private var muteSoloRow: some View {
        switch kind {
        case .input(let strip):
            HStack(spacing: 4) {
                toggleButton(label: "M", active: strip.muted, activeColor: MixerTheme.muteOn) {
                    viewModel.toggleMute(forStrip: strip)
                }
                toggleButton(label: "S", active: strip.soloed, activeColor: MixerTheme.soloOn) {
                    viewModel.toggleSolo(forStrip: strip)
                }
            }
        case .main(let output):
            toggleButton(label: "M", active: output.muted, activeColor: MixerTheme.muteOn) {
                viewModel.toggleOutputMute()
            }
        }
    }

    private func toggleButton(label: String, active: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 16)
                .background(active ? activeColor : MixerTheme.assignInactive)
                .foregroundStyle(active ? Color.black.opacity(0.8) : MixerTheme.assignInactiveFg)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name plate

    private var namePlateRow: some View {
        let (label, color): (String, Color) = {
            switch kind {
            case .input(let strip): (strip.label, MixerTheme.namePlateInput)
            case .main(let output): (output.label, MixerTheme.namePlateMain)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MixerTheme.namePlateText)
            .frame(maxWidth: .infinity)
            .frame(height: MixerTheme.Metrics.namePlateHeight)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Shared placeholder (rows that don't apply to this strip kind)

    private var placeholderDash: some View {
        Text("—")
            .font(.system(size: 11))
            .foregroundStyle(MixerTheme.textSecondary)
    }
}

/// A dB-value text field that lets the user type an exact gain. Editing uses
/// local state so in-progress typing (e.g. a lone "-") isn't immediately
/// overwritten by the live model value; the value only commits on submit or
/// on losing focus, and re-syncs from the model whenever it changes
/// elsewhere (e.g. the fader is dragged) while the field isn't focused.
private struct DBField: View {
    let value: Float
    let onCommit: (Float) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 10, design: .monospaced))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused { text = FaderTaper.displayString(forDB: newValue) }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func commit() {
        if let parsed = FaderTaper.parseDB(text) {
            onCommit(parsed)
            text = FaderTaper.displayString(forDB: parsed)
        } else {
            // Unparseable input reverts to the last known-good value.
            text = FaderTaper.displayString(forDB: value)
        }
    }
}

/// The dB tick column shared by the fader and the meter next to it. Both
/// read positions from `FaderTaper.position(forDB:)`, so the printed numbers
/// always line up with the fader's travel and the meter's fill.
struct ConsoleScaleView: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach(FaderTaper.scaleTicks, id: \.self) { db in
                let position = CGFloat(FaderTaper.position(forDB: db))
                Text(String(format: "%.0f", db))
                    .font(.system(size: 8))
                    .foregroundStyle(MixerTheme.scaleText)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * (1 - position))
            }
        }
        .frame(width: 18)
    }
}
