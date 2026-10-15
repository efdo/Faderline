import SwiftUI
import OSLog
import Synchronization

private let logger = Logger(subsystem: "com.faderline", category: "MixerViewModel")

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

    /// Engine start/stop runs one at a time on this queue (never on main —
    /// see agents.md gotcha #2). `rebuildGeneration` lets queued rebuilds
    /// that were superseded by a newer request skip their start.
    @ObservationIgnored private let engineQueue = DispatchQueue(label: "com.faderline.engine-lifecycle", qos: .userInitiated)
    @ObservationIgnored private let rebuildGeneration = RebuildGeneration()
    private var inputMeterAnimationUntil: [Int: Date] = [:]
    private var outputMeterAnimationUntil: Date = .distantPast

    private static let meterPollInterval: TimeInterval = 1.0 / 15.0
    private static let meterValueEpsilon: Float = 0.0005
    private static let meterPeakAnimationDuration: TimeInterval = 1.5
    private static let disableMetersDefaultsKey = "DisableMeters"

    init() {
        inputStrips = [
            InputStripViewModel(id: 0, label: "Input 1"),
            InputStripViewModel(id: 1, label: "Input 2"),
        ]
        mainOutput = OutputStripViewModel(id: 0, label: "Main Output")

        loadConfiguration()
        deviceManager.onDevicesChanged = { [weak self] in self?.reconcileSelectedDevices() }
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
        // Invalidate queued rebuilds so none restart the engine after exit.
        rebuildGeneration.next()
        mixerEngine.stop()
    }

    // MARK: - Actions

    func selectInputDevice(_ device: AudioDevice, forStrip strip: InputStripViewModel) {
        strip.selectedDevice = device
        strip.leftChannelIndex = 0
        strip.rightChannelIndex = min(1, max(0, device.inputChannelCount - 1))
        rebuildEngine()
    }

    /// After a hot-plug change, clear any selection whose device is gone so
    /// the strip shows "Select Device…" instead of silently following a
    /// different (e.g. system default) device. Devices that reappear with a
    /// new object ID are refreshed in place.
    private func reconcileSelectedDevices() {
        var changed = false
        for strip in inputStrips where strip.selectedDevice.id != AudioDevice.none.id {
            if let current = deviceManager.inputDevices.first(where: { $0.uid == strip.selectedDevice.uid }) {
                if current != strip.selectedDevice {
                    strip.selectedDevice = current
                    let maxIndex = max(0, current.inputChannelCount - 1)
                    strip.leftChannelIndex = min(strip.leftChannelIndex, maxIndex)
                    strip.rightChannelIndex = min(strip.rightChannelIndex, maxIndex)
                    changed = true
                }
            } else {
                logger.notice("Input device '\(strip.selectedDevice.name, privacy: .public)' disappeared; clearing \(strip.label, privacy: .public)")
                strip.selectedDevice = .none
                strip.leftChannelIndex = 0
                strip.rightChannelIndex = 1
                strip.meter.levelLeft = 0
                strip.meter.levelRight = 0
                strip.meter.peakLeft = 0
                strip.meter.peakRight = 0
                changed = true
            }
        }
        if mainOutput.selectedDevice.id != AudioDevice.none.id {
            if let current = deviceManager.outputDevices.first(where: { $0.uid == mainOutput.selectedDevice.uid }) {
                if current != mainOutput.selectedDevice {
                    mainOutput.selectedDevice = current
                    changed = true
                }
            } else {
                logger.notice("Output device '\(self.mainOutput.selectedDevice.name, privacy: .public)' disappeared; clearing Main Output")
                mainOutput.selectedDevice = .none
                changed = true
            }
        }
        if changed { rebuildEngine() }
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
        strip.meter.clipped = false
    }

    func resetOutputClip() {
        mainOutput.meter.clipped = false
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
        let output = ActiveMixerEngine.OutputConfig(
            deviceID: mainOutput.selectedDevice.id,
            volume: mainOutput.gain,
            mute: mainOutput.muted
        )
        saveConfiguration()

        // `AudioComponentInstanceNew` (called deep inside `start()`) makes a
        // synchronous Mach IPC call to coreaudiod whose reply is dispatched on
        // the main thread. Calling it on the main thread therefore deadlocks.
        // Run `start()` on a background thread so the main run loop stays free
        // to receive and dispatch coreaudiod's reply.
        let engine = mixerEngine
        let latencyMode: ActiveMixerEngine.LatencyMode = lowLatencyModeEnabled ? .low : .normal
        let generationCounter = rebuildGeneration
        let generation = generationCounter.next()
        engineQueue.async {
            // A newer rebuild is queued behind us; let it build the final graph.
            guard generationCounter.isCurrent(generation) else { return }
            engine.latencyMode = latencyMode
            do {
                try engine.start(inputs: inputs, output: output)
                let isRunning = engine.isRunning
                DispatchQueue.main.async {
                    logger.notice("✅ Engine started successfully, isRunning=\(isRunning, privacy: .public)")
                }
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async {
                    logger.error("❌ MixerEngine failed to start: \(error, privacy: .public)")
                    engine.lastError = desc
                }
            }
        }
    }

    // MARK: - Level metering

    private func startLevelPolling() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: Self.meterPollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if UserDefaults.standard.bool(forKey: Self.disableMetersDefaultsKey) {
                return
            }
            let meterTimestamp = Date()
            // Copy engine levels to view models
            let peaks = self.mixerEngine.inputPeaks
            let inputLevels = self.mixerEngine.inputLevels
            for strip in self.inputStrips {
                var changed = false
                if let levels = inputLevels[strip.id] {
                    changed = self.publish(levels.left, to: &strip.meter.levelLeft) || changed
                    changed = self.publish(levels.right, to: &strip.meter.levelRight) || changed
                } else {
                    changed = self.publish(strip.meter.levelLeft * 0.9, to: &strip.meter.levelLeft) || changed
                    changed = self.publish(strip.meter.levelRight * 0.9, to: &strip.meter.levelRight) || changed
                }
                if let peak = peaks[strip.id] {
                    changed = self.publish(peak.left, to: &strip.meter.peakLeft) || changed
                    changed = self.publish(peak.right, to: &strip.meter.peakRight) || changed
                    if peak.left > Self.meterValueEpsilon || peak.right > Self.meterValueEpsilon {
                        self.inputMeterAnimationUntil[strip.id] = meterTimestamp.addingTimeInterval(Self.meterPeakAnimationDuration)
                    }
                    if peak.left >= 1.0 || peak.right >= 1.0 {
                        strip.meter.clipped = true
                    }
                }
                if changed || meterTimestamp < self.inputMeterAnimationUntil[strip.id, default: .distantPast] {
                    strip.meter.timestamp = meterTimestamp
                }
            }
            var outputChanged = false
            let outputLevel = self.mixerEngine.outputLevel
            outputChanged = self.publish(outputLevel.left, to: &self.mainOutput.meter.levelLeft) || outputChanged
            outputChanged = self.publish(outputLevel.right, to: &self.mainOutput.meter.levelRight) || outputChanged
            let outputPeak = self.mixerEngine.outputPeak
            outputChanged = self.publish(outputPeak.left, to: &self.mainOutput.meter.peakLeft) || outputChanged
            outputChanged = self.publish(outputPeak.right, to: &self.mainOutput.meter.peakRight) || outputChanged
            if outputPeak.left > Self.meterValueEpsilon || outputPeak.right > Self.meterValueEpsilon {
                self.outputMeterAnimationUntil = meterTimestamp.addingTimeInterval(Self.meterPeakAnimationDuration)
            }
            if outputPeak.left >= 1.0 || outputPeak.right >= 1.0 {
                self.mainOutput.meter.clipped = true
            }
            if outputChanged || meterTimestamp < self.outputMeterAnimationUntil {
                self.mainOutput.meter.timestamp = meterTimestamp
            }
        }

        #if DEBUG
        // Log diagnostics every 3 seconds to help with debugging.
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.mixerEngine.isRunning else { return }
            logger.info("diagnostics:\n\(self.mixerEngine.diagnostics, privacy: .public)")
        }
        #endif
    }

    private func publish(_ newValue: Float, to currentValue: inout Float) -> Bool {
        guard abs(newValue - currentValue) > Self.meterValueEpsilon else { return false }
        currentValue = newValue
        return true
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

/// Monotonic rebuild counter shared with the engine lifecycle queue.
private final class RebuildGeneration: Sendable {
    private let value = Atomic<Int>(0)

    @discardableResult
    func next() -> Int {
        value.add(1, ordering: .acquiringAndReleasing).newValue
    }

    func isCurrent(_ generation: Int) -> Bool {
        value.load(ordering: .acquiring) == generation
    }
}
