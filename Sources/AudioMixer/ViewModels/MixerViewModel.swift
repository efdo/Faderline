import SwiftUI
import CoreAudio
import OSLog

private let logger = Logger(subsystem: "com.audiomixer", category: "MixerViewModel")

/// The engine implementation in use. Switch back to `LegacyMixerEngine`
/// (AVAudioEngine-based) here for A/B comparison during hardware testing.
typealias ActiveMixerEngine = HALMixerEngine

/// Top-level ViewModel coordinating all strips and the audio engine.
@Observable
final class MixerViewModel {
    let deviceManager = DeviceManager()
    let mixerEngine = ActiveMixerEngine()
    let virtualDriverManager = VirtualDriverManager()

    var inputStrips: [InputStripViewModel]
    /// Optional hardware output used for local monitoring of the mix. The
    /// virtual microphone feed (when installed) is independent of this and
    /// always receives the mix while the engine is running.
    var monitorOutput: OutputStripViewModel
    var lowLatencyModeEnabled = false
    /// Whether the post-mix bus is also sent to `monitorOutput`. Does not
    /// affect the virtual microphone feed.
    var monitoringEnabled = true

    private var levelTimer: Timer?

    /// Input devices selectable in a strip, excluding AudioMixer's own
    /// virtual microphone (it exposes an input side too; routing it back
    /// into itself would create feedback).
    var selectableInputDevices: [AudioDevice] {
        deviceManager.inputDevices.filter { $0.uid != VirtualDriverManager.virtualDeviceUID }
    }

    /// Hardware devices selectable for monitoring, excluding the virtual
    /// microphone (it is never a valid monitor target).
    var selectableMonitorDevices: [AudioDevice] {
        deviceManager.outputDevices.filter { $0.uid != VirtualDriverManager.virtualDeviceUID }
    }

    init() {
        inputStrips = [
            InputStripViewModel(id: 0, label: "Input 1"),
            InputStripViewModel(id: 1, label: "Input 2"),
        ]
        monitorOutput = OutputStripViewModel(id: 0, label: "Monitor Output")

        loadConfiguration()
        startLevelPolling()
        // Defer engine start to the next main-run-loop cycle so the run loop
        // is already live when AudioComponentInstanceNew's Mach IPC response
        // needs to be dispatched back to the main thread. Calling this during
        // App.init() would cause a deadlock (response can never be delivered).
        DispatchQueue.main.async { [weak self] in self?.rebuildEngine() }
    }

    deinit {
        levelTimer?.invalidate()
        mixerEngine.stop()
    }

    /// Call on app termination (willTerminateNotification) so coreaudiod
    /// receives proper IOProc-dispose notifications before the process exits.
    /// Without this, killed instances leave orphaned HAL state in coreaudiod
    /// that blocks IOProc registration for the next launch.
    func stopEngine() {
        mixerEngine.stop()
    }

    // MARK: - Actions

    func selectInputDevice(_ device: AudioDevice, forStrip strip: InputStripViewModel) {
        strip.selectedDevice = device
        strip.leftChannelIndex = 0
        strip.rightChannelIndex = min(1, device.inputChannelCount - 1)
        rebuildEngine()
    }

    func selectMonitorDevice(_ device: AudioDevice) {
        monitorOutput.selectedDevice = device
        rebuildEngine()
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        guard monitoringEnabled != enabled else { return }
        monitoringEnabled = enabled
        rebuildEngine()
    }

    func setLowLatencyModeEnabled(_ enabled: Bool) {
        guard lowLatencyModeEnabled != enabled else { return }
        lowLatencyModeEnabled = enabled
        rebuildEngine()
    }

    func updateVolume(_ volume: Float, forStrip strip: InputStripViewModel) {
        strip.volume = volume
        mixerEngine.setVolume(strip.effectiveVolume, forInput: strip.id)
        saveConfiguration()
    }

    func toggleBoost(forStrip strip: InputStripViewModel) {
        strip.boostEnabled.toggle()
        mixerEngine.setVolume(strip.effectiveVolume, forInput: strip.id)
        saveConfiguration()
    }

    func toggleRouteToMain(forStrip strip: InputStripViewModel) {
        strip.routeToMain.toggle()
        mixerEngine.setRouteToMain(strip.routeToMain, forInput: strip.id)
        saveConfiguration()
    }

    func setLeftChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.leftChannelIndex = index
        rebuildEngine()
    }

    func setRightChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.rightChannelIndex = index
        rebuildEngine()
    }

    // MARK: - Virtual driver lifecycle

    /// Stops the engine, opens the install/update package (Installer.app
    /// prompts for administrator authorization), waits for the virtual
    /// device to appear once coreaudiod restarts, then rebuilds the engine
    /// so the virtual microphone starts receiving the mix immediately.
    func installOrUpdateVirtualDriver() {
        guard virtualDriverManager.beginInstallOrUpdate() else { return }
        mixerEngine.stop()
        Task { @MainActor in
            _ = await virtualDriverManager.waitForDevicePresence(expectPresent: true)
            self.rebuildEngine()
        }
    }

    /// Stops the engine, opens the removal package, waits for the virtual
    /// device to disappear, then rebuilds the engine using the
    /// hardware-only fallback path.
    func removeVirtualDriver() {
        guard virtualDriverManager.beginRemoval() else { return }
        mixerEngine.stop()
        Task { @MainActor in
            _ = await virtualDriverManager.waitForDevicePresence(expectPresent: false)
            self.rebuildEngine()
        }
    }

    // MARK: - Engine management

    private func rebuildEngine() {
        // Snapshot config values on the calling (main) thread before touching
        // the audio engine, so the background start closure captures plain
        // value types and avoids accessing @Observable properties off-thread.
        logger.info("rebuildEngine: monitor=\(self.monitorOutput.selectedDevice.name, privacy: .public) (\(self.monitorOutput.selectedDevice.id, privacy: .public)) enabled=\(self.monitoringEnabled, privacy: .public)")
        logger.info("rebuildEngine: virtual=\(self.virtualDriverManager.virtualDeviceID.map(String.init) ?? "none", privacy: .public) latencyMode=\(self.lowLatencyModeEnabled ? "low" : "normal", privacy: .public)")
        for strip in inputStrips {
            logger.info("rebuildEngine: input[\(strip.id, privacy: .public)] '\(strip.selectedDevice.name, privacy: .public)' id=\(strip.selectedDevice.id, privacy: .public) L=ch\(strip.leftChannelIndex, privacy: .public) R=ch\(strip.rightChannelIndex, privacy: .public) route=\(strip.routeToMain, privacy: .public)")
        }

        let inputs = inputStrips.map { strip in
            ActiveMixerEngine.InputConfig(
                deviceID: strip.selectedDevice.id,
                leftChannel: strip.leftChannelIndex,
                rightChannel: strip.rightChannelIndex,
                volume: strip.effectiveVolume,
                routeToMain: strip.routeToMain
            )
        }
        let output = ActiveMixerEngine.OutputConfig(
            virtualDeviceID: virtualDriverManager.virtualDeviceID ?? AudioDeviceID(kAudioObjectUnknown),
            monitorDeviceID: monitoringEnabled ? monitorOutput.selectedDevice.id : AudioDeviceID(kAudioObjectUnknown)
        )
        saveConfiguration()

        // `AudioComponentInstanceNew` (called deep inside `start()`) makes a
        // synchronous Mach IPC call to coreaudiod whose reply is dispatched on
        // the main thread. Calling it on the main thread therefore deadlocks.
        // Run `start()` on a background thread so the main run loop stays free
        // to receive and dispatch coreaudiod's reply.
        let engine = mixerEngine
        engine.latencyMode = lowLatencyModeEnabled ? .low : .normal
        Task.detached(priority: .userInitiated) {
            do {
                try engine.start(inputs: inputs, output: output)
                let isRunning = engine.isRunning
                await MainActor.run {
                    logger.notice("✅ Engine started successfully, isRunning=\(isRunning, privacy: .public)")
                }
            } catch {
                let desc = error.localizedDescription
                await MainActor.run {
                    logger.error("❌ MixerEngine failed to start: \(error, privacy: .public)")
                    engine.lastError = desc
                }
            }
        }
    }

    // MARK: - Level metering

    private func startLevelPolling() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Copy engine levels to view models
            for strip in self.inputStrips {
                if let levels = self.mixerEngine.inputLevels[strip.id] {
                    strip.levelLeft = levels.left
                    strip.levelRight = levels.right
                } else {
                    strip.levelLeft *= 0.9
                    strip.levelRight *= 0.9
                }
            }
            // The engine's outputLevel reflects the post-mix bus, which is
            // exactly what's fed to whichever device is primary (the
            // virtual microphone when installed, or the monitor device
            // directly otherwise) — safe to reuse for both meters.
            self.monitorOutput.levelLeft = self.mixerEngine.outputLevel.left
            self.monitorOutput.levelRight = self.mixerEngine.outputLevel.right
        }

        // Log diagnostics every 3 seconds to help with debugging.
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.mixerEngine.isRunning else { return }
            logger.info("diagnostics:\n\(self.mixerEngine.diagnostics, privacy: .public)")
        }
    }

    // MARK: - Persistence

    private func saveConfiguration() {
        let config = MixerConfiguration(
            inputs: inputStrips.map { strip in
                MixerConfiguration.InputStripConfig(
                    deviceUID: strip.selectedDevice.uid,
                    leftChannelIndex: strip.leftChannelIndex,
                    rightChannelIndex: strip.rightChannelIndex,
                    volume: strip.volume,
                    boostEnabled: strip.boostEnabled,
                    routeToMain: strip.routeToMain
                )
            },
            monitorOutput: MixerConfiguration.OutputStripConfig(
                deviceUID: monitorOutput.selectedDevice.uid
            ),
            lowLatencyModeEnabled: lowLatencyModeEnabled,
            monitoringEnabled: monitoringEnabled
        )
        config.save()
    }

    private func loadConfiguration() {
        let config = MixerConfiguration.load()

        for (i, stripConfig) in config.inputs.enumerated() where i < inputStrips.count {
            let strip = inputStrips[i]
            if let device = deviceManager.device(forUID: stripConfig.deviceUID) {
                strip.selectedDevice = device
            }
            strip.leftChannelIndex = stripConfig.leftChannelIndex
            strip.rightChannelIndex = stripConfig.rightChannelIndex
            strip.volume = stripConfig.volume
            strip.boostEnabled = stripConfig.boostEnabled
            strip.routeToMain = stripConfig.routeToMain
        }

        if let device = deviceManager.device(forUID: config.monitorOutput.deviceUID) {
            monitorOutput.selectedDevice = device
        }
        lowLatencyModeEnabled = config.lowLatencyModeEnabled
        monitoringEnabled = config.monitoringEnabled
    }
}
