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
        .padding(.vertical, MixerTheme.Metrics.stripVerticalPadding)
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
            ConsolePicker(selection: Binding(
                get: { strip.selectedDevice },
                set: { viewModel.selectInputDevice($0, forStrip: strip) }
            ), options: deviceOptions(selected: strip.selectedDevice, available: viewModel.deviceManager.inputDevices),
                          label: { $0.name }, accessibilityLabel: "\(strip.label) device")
            .frame(maxWidth: .infinity)
        case .main(let output):
            ConsolePicker(selection: Binding(
                get: { output.selectedDevice },
                set: { viewModel.selectOutputDevice($0) }
            ), options: deviceOptions(selected: output.selectedDevice, available: viewModel.deviceManager.outputDevices),
                          label: { $0.name }, accessibilityLabel: "\(output.label) device")
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Channels

    private func deviceOptions(selected: AudioDevice, available: [AudioDevice]) -> [AudioDevice] {
        [AudioDevice.none] + (selected.uid.isEmpty || available.contains(selected) ? [] : [selected]) + available
    }

    @ViewBuilder
    private var channelsRow: some View {
        switch kind {
        case .input(let strip):
            if strip.hasDevice {
                let current = strip.channelMode
                let options = strip.availableChannelModes
                let selectedLabel = current?.label ?? "Ch \(strip.leftChannelIndex + 1) / \(strip.rightChannelIndex + 1)"
                ConsolePicker(selection: Binding(
                    get: { selectedLabel },
                    set: { label in
                        if let mode = options.first(where: { $0.label == label }) {
                            viewModel.setChannelMode(mode, forStrip: strip)
                        }
                    }
                ), options: (options.map(\.label).contains(selectedLabel) ? [] : [selectedLabel]) + options.map(\.label),
                              label: { $0 }, accessibilityLabel: "\(strip.label) channels")
                .frame(maxWidth: .infinity)
            } else {
                let label = strip.selectedDevice.uid.isEmpty ? "—"
                    : strip.channelMode?.label ?? "Ch \(strip.leftChannelIndex + 1) / \(strip.rightChannelIndex + 1)"
                ConsolePicker(selection: .constant(label), options: [label],
                              label: { $0 }, accessibilityLabel: "\(strip.label) channels")
                .disabled(true)
                .frame(maxWidth: .infinity)
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
            .disabled(!strip.hasDevice)
            .opacity(strip.hasDevice ? 1 : 0.35)
        case .main:
            placeholderDash
        }
    }

    // MARK: - Pan

    @ViewBuilder
    private var panRow: some View {
        switch kind {
        case .input(let strip):
            HStack(alignment: .bottom, spacing: 4) {
                Text("L")
                PanKnobView(pan: Binding(
                    get: { strip.pan },
                    set: { viewModel.setPan($0, forStrip: strip) }
                ))
                .frame(
                    width: MixerTheme.Metrics.panKnobDiameter,
                    height: MixerTheme.Metrics.panKnobDiameter
                )
                Text("R")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(MixerTheme.textLabel)
        case .main:
            placeholderDash
        }
    }

    // MARK: - dB field

    @ViewBuilder
    private var dbRow: some View {
        let revision = viewModel.profileRecallRevision
        switch kind {
        case .input(let strip):
            DBField(value: strip.gainDB, revision: revision) {
                if revision == viewModel.profileRecallRevision { viewModel.setGainDB($0, forStrip: strip) }
            }
            .id(revision)
        case .main(let output):
            DBField(value: output.gainDB, revision: revision) {
                if revision == viewModel.profileRecallRevision { viewModel.setOutputGainDB($0) }
            }
            .id(revision)
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
                    meter: strip.meter,
                    onResetClip: { viewModel.resetClip(forStrip: strip) }
                )
            case .main(let output):
                FaderView(db: Binding(
                    get: { output.gainDB },
                    set: { viewModel.setOutputGainDB($0) }
                ))
                ConsoleScaleView()
                ChannelMeterView(
                    meter: output.meter,
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
                .help(strip.muted ? "Mute: On - click to unmute this input" : "Mute: Off - click to mute this input")
                .accessibilityLabel("Mute \(strip.label)")
                toggleButton(label: "S", active: strip.soloed, activeColor: MixerTheme.soloOn) {
                    viewModel.toggleSolo(forStrip: strip)
                }
                .help(strip.soloed ? "Solo: On - click to disable solo" : "Solo: Off - click to hear only soloed inputs routed to Main")
                .accessibilityLabel("Solo \(strip.label)")
            }
        case .main(let output):
            toggleButton(label: "M", active: output.muted, activeColor: MixerTheme.muteOn) {
                viewModel.toggleOutputMute()
            }
            .help(output.muted ? "Mute: On - click to unmute Main Output" : "Mute: Off - click to mute Main Output")
            .accessibilityLabel("Mute Main Output")
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

/// Native pop-ups retain standard keyboard navigation and focus indicators.
/// Explicit sizing makes short channel labels fill the same width as devices.
private struct ConsolePicker<Value: Equatable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(label)
        if button.itemTitles != titles {
            button.removeAllItems()
            // Add individually: duplicate device names must retain distinct indices.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        button.selectItem(at: options.firstIndex(of: selection) ?? -1)
        button.toolTip = label(selection)
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(accessibilityLabel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: ConsolePicker

        init(_ parent: ConsolePicker) {
            self.parent = parent
        }

        @objc func select(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.options.indices.contains(index) else { return }
            let value = parent.options[index]
            sender.toolTip = parent.label(value)
            parent.selection = value
        }
    }
}

/// A dB-value text field that lets the user type an exact gain. Editing uses
/// local state so in-progress typing (e.g. a lone "-") isn't immediately
/// overwritten by the live model value; the value only commits on submit or
/// on losing focus, and re-syncs from the model whenever it changes
/// elsewhere (e.g. the fader is dragged) while the field isn't focused.
private struct DBField: View {
    @Environment(MixerViewModel.self) private var viewModel
    let value: Float
    let revision: Int
    let onCommit: (Float) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 10, design: .monospaced))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .help(text)
            .onChange(of: value, initial: true) { _, newValue in
                if !isFocused { text = FaderTaper.displayString(forDB: newValue) }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    updatePendingEdit()
                } else {
                    commit()
                }
            }
            .onChange(of: text) { _, _ in
                if isFocused { updatePendingEdit() }
            }
            .onReceive(NotificationCenter.default.publisher(for: MixerViewModel.commitPendingEditsNotification)) { _ in
                if isFocused { commit() }
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
        viewModel.setPendingGainEdit(false, revision: revision)
    }

    private func updatePendingEdit() {
        viewModel.setPendingGainEdit(text != FaderTaper.displayString(forDB: value), revision: revision)
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
