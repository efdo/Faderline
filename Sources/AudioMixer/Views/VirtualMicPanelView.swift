import SwiftUI

/// Panel showing the AudioMixer virtual microphone status and controls:
/// install/update/remove the driver, and level meters for the mix that's
/// actually being fed to it once it's live.
struct VirtualMicPanelView: View {
    @Environment(MixerViewModel.self) private var viewModel

    private var driverState: VirtualDriverManager.State {
        viewModel.virtualDriverManager.state
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Virtual Microphone")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MixerTheme.textLabel)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(MixerTheme.textSecondary)
                }

                Text(guidanceText)
                    .font(.caption2)
                    .foregroundStyle(MixerTheme.textMeterLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if showsInstallButton {
                        Button(installButtonTitle) {
                            viewModel.installOrUpdateVirtualDriver()
                        }
                        .disabled(isBusy)
                    }
                    if showsRemoveButton {
                        Button("Remove", role: .destructive) {
                            viewModel.removeVirtualDriver()
                        }
                        .disabled(isBusy)
                    }
                }

                if isVirtualMicLive {
                    HStack(spacing: 4) {
                        Text("L")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MixerTheme.textMeterLabel)
                            .frame(width: 12)
                        VUMeterView(level: viewModel.monitorOutput.levelLeft)
                    }
                    HStack(spacing: 4) {
                        Text("R")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(MixerTheme.textMeterLabel)
                            .frame(width: 12)
                        VUMeterView(level: viewModel.monitorOutput.levelRight)
                    }
                }
            }
            .padding(8)
        }
        .backgroundStyle(MixerTheme.stripBg)
    }

    // MARK: - Derived display state

    private var isVirtualMicLive: Bool {
        viewModel.virtualDriverManager.virtualDeviceID != nil && viewModel.mixerEngine.isRunning
    }

    private var isBusy: Bool {
        switch driverState {
        case .installing, .removing: true
        default: false
        }
    }

    private var showsInstallButton: Bool {
        switch driverState {
        case .notInstalled, .updateAvailable, .error: true
        default: false
        }
    }

    private var showsRemoveButton: Bool {
        switch driverState {
        case .installed, .updateAvailable: true
        default: false
        }
    }

    private var installButtonTitle: String {
        if case .updateAvailable = driverState { return "Update" }
        return "Install"
    }

    private var statusColor: Color {
        switch driverState {
        case .installed: MixerTheme.engineRunning
        case .updateAvailable: MixerTheme.boostActive
        case .installing, .removing: MixerTheme.textSecondary
        case .notInstalled: MixerTheme.engineStopped
        case .error: MixerTheme.errorBannerBg
        }
    }

    private var statusText: String {
        switch driverState {
        case .notInstalled: "Not installed"
        case .installed(let version): "Installed (v\(version))"
        case .updateAvailable(let installed, let available): "Update available (v\(installed) → v\(available))"
        case .installing: "Installing…"
        case .removing: "Removing…"
        case .error(let message): message
        }
    }

    private var guidanceText: String {
        switch driverState {
        case .notInstalled:
            return "Install the virtual microphone to use this mix directly as your microphone in Teams, Zoom, or any other app — no need for BlackHole or similar loopback drivers."
        case .updateAvailable:
            return "A newer version of the virtual microphone driver is available."
        case .installing:
            return "Follow the prompts in the installer window. This briefly restarts Core Audio."
        case .removing:
            return "Follow the prompts in the installer window. This briefly restarts Core Audio."
        case .error:
            return "Try again, or install manually — see the project documentation."
        case .installed:
            return "Select “AudioMixer Virtual Microphone” as your microphone in Teams, Zoom, or any other app."
        }
    }
}
