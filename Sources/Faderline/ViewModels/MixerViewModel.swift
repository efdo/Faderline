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
    private(set) var profileLibrary = MixerProfileLibrary(configuration: .default)
    private(set) var profileError: String?
    private(set) var profilesUnavailable = false
    var profileDialog: ProfileDialog?
    private(set) var profileRecallRevision = 0
    private(set) var hasPendingGainEdit = false
    static let commitPendingEditsNotification = Notification.Name("FaderlineCommitPendingEdits")

    @ObservationIgnored private let profileStore: MixerProfileStore
    @ObservationIgnored private let startsAudio: Bool
    private var isRebuilding = false

    private var levelTimer: Timer?

    /// Engine start/stop runs one at a time on this queue (never on main —
    /// see agents.md gotcha #2). `rebuildGeneration` lets queued rebuilds
    /// that were superseded by a newer request skip their start.
    @ObservationIgnored private let engineQueue = DispatchQueue(label: "com.faderline.engine-lifecycle", qos: .userInitiated)
    @ObservationIgnored private let rebuildGeneration = RebuildGeneration()
    /// Set once termination begins; all later rebuild requests are rejected so
    /// nothing can recreate AUHAL units after the final stop.
    @ObservationIgnored private var isShuttingDown = false
    private var inputMeterAnimationUntil: [Int: Date] = [:]
    private var outputMeterAnimationUntil: Date = .distantPast

    private static let meterPollInterval: TimeInterval = 1.0 / 15.0
    private static let meterValueEpsilon: Float = 0.0005
    private static let meterPeakAnimationDuration: TimeInterval = 1.5
    private static let disableMetersDefaultsKey = "DisableMeters"

    init(profileStore: MixerProfileStore = MixerProfileStore(), startsAudio: Bool = true) {
        self.profileStore = profileStore
        self.startsAudio = startsAudio
        inputStrips = [
            InputStripViewModel(id: 0, label: "Input 1"),
            InputStripViewModel(id: 1, label: "Input 2"),
        ]
        mainOutput = OutputStripViewModel(id: 0, label: "Main Output")

        loadConfiguration()
        deviceManager.onDevicesChanged = { [weak self] in self?.reconcileSelectedDevices() }
        guard startsAudio else { return }
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

    /// Call on app termination so coreaudiod receives proper IOProc-dispose
    /// notifications before the process exits. Without this, killed instances
    /// leave orphaned HAL state in coreaudiod that blocks IOProc registration
    /// for the next launch. The stop is queued behind any in-flight start so
    /// it can't be overtaken; `completion` runs on main once cleanup is done.
    func shutdownEngine(completion: @escaping () -> Void) {
        NotificationCenter.default.post(name: Self.commitPendingEditsNotification, object: self)
        saveConfiguration()
        // Invalidate queued rebuilds so none restart the engine after exit.
        isShuttingDown = true
        rebuildGeneration.next()
        let engine = mixerEngine
        engineQueue.async {
            engine.stop()
            logger.notice("Engine shut down for termination")
            // Run-loop delivery (common modes) still fires if termination was
            // requested from inside a main-queue block.
            RunLoop.main.perform(inModes: [.common], block: completion)
        }
    }

    // MARK: - Actions

    func selectInputDevice(_ device: AudioDevice, forStrip strip: InputStripViewModel) {
        guard strip.selectedDevice != device else { return }
        strip.selectedDevice = device
        strip.leftChannelIndex = 0
        strip.rightChannelIndex = min(1, max(0, device.inputChannelCount - 1))
        rebuildEngine()
    }

    private func reconcileSelectedDevices() {
        let previous = inputStrips.map(\.selectedDevice) + [mainOutput.selectedDevice]
        resolveSelectedDevices(snapshot: currentSnapshot)
        if previous != inputStrips.map(\.selectedDevice) + [mainOutput.selectedDevice] {
            resetMeters()
            rebuildEngine()
        }
    }

    func selectOutputDevice(_ device: AudioDevice) {
        mainOutput.selectedDevice = device
        rebuildEngine()
    }

    func setLowLatencyModeEnabled(_ enabled: Bool) {
        guard lowLatencyModeEnabled != enabled else { return }
        lowLatencyModeEnabled = enabled
        profileStore.lowLatencyModeEnabled = enabled
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
        saveConfiguration()
        guard startsAudio else { return }
        guard !isShuttingDown else {
            return
        }
        // Snapshot config values on the calling (main) thread before touching
        // the audio engine, so the background start closure captures plain
        // value types and avoids accessing @Observable properties off-thread.
        logger.info("rebuildEngine: output=\(self.mainOutput.selectedDevice.name, privacy: .public) (\(self.mainOutput.selectedDevice.id, privacy: .public)) gainDB=\(self.mainOutput.gainDB, privacy: .public)")
        logger.info("rebuildEngine: latencyMode=\(self.lowLatencyModeEnabled ? "low" : "normal", privacy: .public)")
        for strip in inputStrips {
            logger.info("rebuildEngine: input[\(strip.id, privacy: .public)] '\(strip.selectedDevice.name, privacy: .public)' id=\(strip.selectedDevice.id, privacy: .public) L=ch\(strip.leftChannelIndex, privacy: .public) R=ch\(strip.rightChannelIndex, privacy: .public) route=\(strip.routeToMain, privacy: .public) gainDB=\(strip.gainDB, privacy: .public) pan=\(strip.pan, privacy: .public) mute=\(strip.muted, privacy: .public) solo=\(strip.soloed, privacy: .public)")
        }

        let resolved = resolvedSnapshot
        let inputs = inputStrips.enumerated().map { index, strip in
            ActiveMixerEngine.InputConfig(
                deviceID: resolved.inputs[index].id,
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
            deviceID: resolved.output.id,
            volume: mainOutput.gain,
            mute: mainOutput.muted
        )
        // `AudioComponentInstanceNew` (called deep inside `start()`) makes a
        // synchronous Mach IPC call to coreaudiod whose reply is dispatched on
        // the main thread. Calling it on the main thread therefore deadlocks.
        // Run `start()` on a background thread so the main run loop stays free
        // to receive and dispatch coreaudiod's reply.
        let engine = mixerEngine
        // Master controls persist across rebuilds; set them here on main (in
        // order with UI toggles) rather than snapshotting into the start call.
        engine.setOutputVolume(mainOutput.gain)
        engine.setOutputMuted(mainOutput.muted)
        let latencyMode: ActiveMixerEngine.LatencyMode = lowLatencyModeEnabled ? .low : .normal
        let generationCounter = rebuildGeneration
        let generation = generationCounter.next()
        isRebuilding = true
        engineQueue.async { [weak self] in
            // A newer rebuild is queued behind us; let it build the final graph.
            guard generationCounter.isCurrent(generation) else { return }
            engine.latencyMode = latencyMode
            do {
                try engine.start(inputs: inputs, output: output)
                let isRunning = engine.isRunning
                DispatchQueue.main.async { [weak self] in
                    guard let self, generationCounter.isCurrent(generation), !self.isShuttingDown else { return }
                    self.isRebuilding = false
                    self.applyLiveParameters()
                    logger.notice("✅ Engine started successfully, isRunning=\(isRunning, privacy: .public)")
                }
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, generationCounter.isCurrent(generation), !self.isShuttingDown else { return }
                    self.isRebuilding = false
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
            guard !self.isRebuilding else { return }
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

    var currentSnapshot: MixerSnapshot {
        MixerSnapshot(configuration: MixerConfiguration(
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
        ))
    }

    private var resolvedSnapshot: ResolvedMixerSnapshot {
        currentSnapshot.resolve(inputDevices: deviceManager.inputDevices, outputDevices: deviceManager.outputDevices)
    }

    private func saveConfiguration() {
        guard !profilesUnavailable else { return }
        do {
            var library = profileLibrary
            try library.updateDraft(currentSnapshot)
            for device in inputStrips.map(\.selectedDevice) + [mainOutput.selectedDevice]
                where device.id != AudioDevice.none.id {
                library.deviceNames[device.uid] = device.name
            }
            try profileStore.save(library)
            profileLibrary = library
            profileError = nil
        } catch {
            // Keep the current draft in memory so a later retry can persist it.
            do { try profileLibrary.updateDraft(currentSnapshot) }
            catch { logger.error("Invalid working mix: \(error, privacy: .public)") }
            reportProfileError(error)
        }
    }

    private func loadConfiguration() {
        do {
            profileLibrary = try profileStore.load()
            profilesUnavailable = false
            profileError = nil
        } catch {
            profilesUnavailable = true
            reportProfileError(error)
        }
        lowLatencyModeEnabled = profileStore.lowLatencyModeEnabled
        applySnapshot(profileLibrary.currentDraft)
    }

    private func applySnapshot(_ config: MixerSnapshot) {
        profileRecallRevision += 1
        hasPendingGainEdit = false
        for (i, stripConfig) in config.inputs.enumerated() {
            let strip = inputStrips[i]
            strip.leftChannelIndex = stripConfig.leftChannelIndex
            strip.rightChannelIndex = stripConfig.rightChannelIndex
            strip.gainDB = stripConfig.gainDB
            strip.pan = stripConfig.pan
            strip.muted = stripConfig.muted
            strip.routeToMain = stripConfig.routeToMain
            strip.soloed = false
        }
        mainOutput.gainDB = config.mainOutput.gainDB
        resolveSelectedDevices(snapshot: config)
        resetMeters()
    }

    private func resolveSelectedDevices(snapshot: MixerSnapshot) {
        func device(uid: String, available: [AudioDevice]) -> AudioDevice {
            if uid.isEmpty { return .none }
            return available.first { $0.uid == uid }
                ?? .unavailable(uid: uid, name: profileLibrary.deviceNames[uid] ?? uid)
        }
        for (index, config) in snapshot.inputs.enumerated() {
            inputStrips[index].selectedDevice = device(uid: config.deviceUID, available: deviceManager.inputDevices)
        }
        mainOutput.selectedDevice = device(uid: snapshot.mainOutput.deviceUID, available: deviceManager.outputDevices)
    }

    private func resetMeters() {
        for meter in inputStrips.map(\.meter) + [mainOutput.meter] {
            meter.levelLeft = 0
            meter.levelRight = 0
            meter.peakLeft = 0
            meter.peakRight = 0
            meter.clipped = false
            meter.timestamp = .now
        }
        inputMeterAnimationUntil.removeAll()
        outputMeterAnimationUntil = .distantPast
    }

    private func applyLiveParameters() {
        for strip in inputStrips {
            mixerEngine.setVolume(strip.gain, forInput: strip.id)
            mixerEngine.setPan(strip.pan, forInput: strip.id)
            mixerEngine.setMute(strip.muted, forInput: strip.id)
            mixerEngine.setRouteToMain(strip.routeToMain, forInput: strip.id)
            mixerEngine.setSolo(strip.soloed, forInput: strip.id)
        }
        mixerEngine.setOutputVolume(mainOutput.gain)
        mixerEngine.setOutputMuted(mainOutput.muted)
    }

    // MARK: - Profiles

    var hasActiveProfile: Bool { !profilesUnavailable && profileLibrary.active != nil }
    var isProfileEdited: Bool { hasActiveProfile && (profileLibrary.isEdited || hasPendingGainEdit) }
    var canSaveProfile: Bool { !profilesUnavailable && (profileLibrary.active == nil || isProfileEdited) }
    var canRevertProfile: Bool { isProfileEdited }
    var windowTitle: String {
        guard !profilesUnavailable, let profile = profileLibrary.active else { return "Faderline" }
        return "Faderline — \(profile.name)" + (isProfileEdited ? " — Edited" : "")
    }

    func setPendingGainEdit(_ pending: Bool, revision: Int) {
        guard revision == profileRecallRevision else { return }
        hasPendingGainEdit = pending
    }

    var availabilityWarning: String? {
        let resolved = resolvedSnapshot
        var problems: [String] = []
        for (index, config) in currentSnapshot.inputs.enumerated()
            where !config.deviceUID.isEmpty && resolved.inputs[index].id == AudioDevice.none.id {
            let strip = inputStrips[index]
            problems.append(strip.hasDevice ? "\(strip.label): saved channels unavailable" : "\(strip.label): device unavailable")
        }
        if !mainOutput.selectedDevice.uid.isEmpty && resolved.output.id == AudioDevice.none.id {
            problems.append("Main Output: device unavailable")
        }
        return problems.isEmpty ? nil : problems.joined(separator: ". ") + ". Selections are preserved."
    }

    func profileNameError(_ name: String, renaming: Bool) -> String? {
        do {
            _ = try profileLibrary.validatedName(name, excluding: renaming ? profileLibrary.activeID : nil)
            return nil
        } catch { return error.localizedDescription }
    }

    @discardableResult
    private func changeProfiles(recalling: Bool = false,
                                _ change: (inout MixerProfileLibrary) throws -> Void) -> Bool {
        guard !profilesUnavailable else { return false }
        NotificationCenter.default.post(name: Self.commitPendingEditsNotification, object: self)
        do {
            var library = profileLibrary
            try library.updateDraft(currentSnapshot)
            let previous = resolvedSnapshot
            let previousChannels = currentSnapshot.inputs.map { [$0.leftChannelIndex, $0.rightChannelIndex] }
            try change(&library)
            try profileStore.save(library)
            profileLibrary = library
            profileError = nil
            if recalling {
                applySnapshot(library.currentDraft)
                let channels = currentSnapshot.inputs.map { [$0.leftChannelIndex, $0.rightChannelIndex] }
                if isRebuilding || previous != resolvedSnapshot || previousChannels != channels
                    || (startsAudio && !mixerEngine.isRunning && resolvedSnapshot.output.id != AudioDevice.none.id) {
                    rebuildEngine()
                } else {
                    applyLiveParameters()
                }
            }
            return true
        } catch {
            reportProfileError(error)
            return false
        }
    }

    /// Selects a profile, or Default when `id` is nil.
    func selectProfile(_ id: UUID?) {
        guard id != profileLibrary.activeID else { return }
        changeProfiles(recalling: true) { try $0.select(id) }
    }

    func saveProfile() {
        guard canSaveProfile else { return }
        guard hasActiveProfile else {
            profileDialog = .saveAs
            return
        }
        changeProfiles { try $0.save() }
    }

    @discardableResult
    func saveProfileAs(_ name: String) -> Bool {
        changeProfiles { try $0.saveAs(name) }
    }

    @discardableResult
    func renameProfile(_ name: String) -> Bool {
        changeProfiles { try $0.rename(name) }
    }

    func revertProfile() {
        guard canRevertProfile else { return }
        changeProfiles(recalling: true) { try $0.revert() }
    }

    func deleteProfile(_ id: UUID) {
        changeProfiles(recalling: id == profileLibrary.activeID) { try $0.delete(id) }
    }

    func retryProfileStorage() {
        if profilesUnavailable {
            loadConfiguration()
            if !profilesUnavailable { rebuildEngine() }
        } else {
            saveConfiguration()
        }
    }

    private func reportProfileError(_ error: Error) {
        logger.error("Profile storage: \(error, privacy: .public)")
        profileError = "Profiles: \(error.localizedDescription) "
            + (profilesUnavailable
               ? "Stored data is untouched. Changes cannot be saved until loading succeeds."
               : "The change could not be saved. Retry to save the working mix.")
    }
}

/// Monotonic rebuild counter shared with the engine lifecycle queue.
final class RebuildGeneration: Sendable {
    private let value = Atomic<Int>(0)

    @discardableResult
    func next() -> Int {
        value.add(1, ordering: .acquiringAndReleasing).newValue
    }

    func isCurrent(_ generation: Int) -> Bool {
        value.load(ordering: .acquiring) == generation
    }
}
