import SwiftUI
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

    var inputStrips: [InputStripViewModel]
    var mainOutput: OutputStripViewModel
    var lowLatencyModeEnabled = false

    private var levelTimer: Timer?

    init() {
        inputStrips = [
            InputStripViewModel(id: 0, label: "Input 1"),
            InputStripViewModel(id: 1, label: "Input 2"),
        ]
        mainOutput = OutputStripViewModel(id: 0, label: "Main Output")

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

    func selectOutputDevice(_ device: AudioDevice) {
        mainOutput.selectedDevice = device
        rebuildEngine()
    }

    func setLowLatencyModeEnabled(_ enabled: Bool) {
        guard lowLatencyModeEnabled != enabled else { return }
        lowLatencyModeEnabled = enabled
        rebuildEngine()
    }

    /// True while any input strip is soloed. Non-soloed strips stay in the
    /// mix graph (still metering) but go silent at the render thread.
    var anySolo: Bool {
        inputStrips.contains { $0.soloed }
    }

    func setGainDB(_ db: Float, forStrip strip: InputStripViewModel) {
        strip.gainDB = db
        mixerEngine.setVolume(strip.gain, forInput: strip.id)
        saveConfiguration()
    }

    func setPan(_ pan: Float, forStrip strip: InputStripViewModel) {
        strip.pan = pan
        mixerEngine.setPan(pan, forInput: strip.id)
        saveConfiguration()
    }

    func toggleMute(forStrip strip: InputStripViewModel) {
        strip.muted.toggle()
        mixerEngine.setMute(strip.muted, forInput: strip.id)
        saveConfiguration()
    }

    /// Solo is transient troubleshooting state, not persisted — launching
    /// into a soloed mix would be confusing.
    func toggleSolo(forStrip strip: InputStripViewModel) {
        strip.soloed.toggle()
        mixerEngine.setSolo(strip.soloed, forInput: strip.id)
    }

    func toggleRouteToMain(forStrip strip: InputStripViewModel) {
        strip.routeToMain.toggle()
        mixerEngine.setRouteToMain(strip.routeToMain, forInput: strip.id)
        saveConfiguration()
    }

    func setOutputGainDB(_ db: Float) {
        mainOutput.gainDB = db
        mixerEngine.setOutputVolume(mainOutput.gain)
        saveConfiguration()
    }

    /// Master mute is transient, not persisted — same reasoning as solo:
    /// relaunching into silence would be a footgun.
    func toggleOutputMute() {
        mainOutput.muted.toggle()
        mixerEngine.setOutputMuted(mainOutput.muted)
    }

    func resetClip(forStrip strip: InputStripViewModel) {
        strip.clipped = false
    }

    func resetOutputClip() {
        mainOutput.clipped = false
    }

    func setLeftChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.leftChannelIndex = index
        rebuildEngine()
    }

    func setRightChannel(_ index: Int, forStrip strip: InputStripViewModel) {
        strip.rightChannelIndex = index
        rebuildEngine()
    }

    func setChannelMode(_ mode: InputStripViewModel.ChannelMode, forStrip strip: InputStripViewModel) {
        switch mode {
        case .mono1:
            strip.leftChannelIndex = 0
            strip.rightChannelIndex = 0
        case .mono2:
            strip.leftChannelIndex = min(1, max(0, strip.selectedDevice.inputChannelCount - 1))
            strip.rightChannelIndex = min(1, max(0, strip.selectedDevice.inputChannelCount - 1))
        case .stereo12:
            strip.leftChannelIndex = 0
            strip.rightChannelIndex = min(1, max(0, strip.selectedDevice.inputChannelCount - 1))
        }
        rebuildEngine()
    }

    // MARK: - Engine management

    private func rebuildEngine() {
        // Snapshot config values on the calling (main) thread before touching
        // the audio engine, so the background start closure captures plain
        // value types and avoids accessing @Observable properties off-thread.
        logger.info("rebuildEngine: output=\(self.mainOutput.selectedDevice.name, privacy: .public) (\(self.mainOutput.selectedDevice.id, privacy: .public)) gainDB=\(self.mainOutput.gainDB, privacy: .public)")
        logger.info("rebuildEngine: latencyMode=\(self.lowLatencyModeEnabled ? "low" : "normal", privacy: .public)")
        for strip in inputStrips {
            logger.info("rebuildEngine: input[\(strip.id, privacy: .public)] '\(strip.selectedDevice.name, privacy: .public)' id=\(strip.selectedDevice.id, privacy: .public) L=ch\(strip.leftChannelIndex, privacy: .public) R=ch\(strip.rightChannelIndex, privacy: .public) route=\(strip.routeToMain, privacy: .public) gainDB=\(strip.gainDB, privacy: .public) pan=\(strip.pan, privacy: .public) mute=\(strip.muted, privacy: .public) solo=\(strip.soloed, privacy: .public)")
        }

        let inputs = inputStrips.map { strip in
            ActiveMixerEngine.InputConfig(
                deviceID: strip.selectedDevice.id,
                leftChannel: strip.leftChannelIndex,
                rightChannel: strip.rightChannelIndex,
                volume: strip.gain,
                routeToMain: strip.routeToMain,
                pan: strip.pan,
                mute: strip.muted,
                solo: strip.soloed
            )
        }
        let output = ActiveMixerEngine.OutputConfig(deviceID: mainOutput.selectedDevice.id, volume: mainOutput.gain)
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
            let peaks = self.mixerEngine.inputPeaks
            for strip in self.inputStrips {
                if let levels = self.mixerEngine.inputLevels[strip.id] {
                    strip.levelLeft = levels.left
                    strip.levelRight = levels.right
                } else {
                    strip.levelLeft *= 0.9
                    strip.levelRight *= 0.9
                }
                if let peak = peaks[strip.id] {
                    strip.peakLeft = peak.left
                    strip.peakRight = peak.right
                    if peak.left >= 1.0 || peak.right >= 1.0 {
                        strip.clipped = true
                    }
                }
            }
            self.mainOutput.levelLeft = self.mixerEngine.outputLevel.left
            self.mainOutput.levelRight = self.mixerEngine.outputLevel.right
            let outputPeak = self.mixerEngine.outputPeak
            self.mainOutput.peakLeft = outputPeak.left
            self.mainOutput.peakRight = outputPeak.right
            if outputPeak.left >= 1.0 || outputPeak.right >= 1.0 {
                self.mainOutput.clipped = true
            }
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
                    gainDB: strip.gainDB,
                    pan: strip.pan,
                    muted: strip.muted,
                    routeToMain: strip.routeToMain
                )
            },
            mainOutput: MixerConfiguration.OutputStripConfig(
                deviceUID: mainOutput.selectedDevice.uid,
                gainDB: mainOutput.gainDB
            ),
            lowLatencyModeEnabled: lowLatencyModeEnabled
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
            strip.gainDB = stripConfig.gainDB
            strip.pan = stripConfig.pan
            strip.muted = stripConfig.muted
            strip.routeToMain = stripConfig.routeToMain
        }

        if let device = deviceManager.device(forUID: config.mainOutput.deviceUID) {
            mainOutput.selectedDevice = device
        }
        mainOutput.gainDB = config.mainOutput.gainDB
        lowLatencyModeEnabled = config.lowLatencyModeEnabled
    }
}
