import Foundation
import Accelerate
import CoreAudio
import Synchronization
import OSLog

private let logger = Logger(subsystem: "com.audiomixer", category: "HALMixerEngine")

/// AUHAL-based mixer engine (LadioCast-style architecture).
///
/// Signal path:
/// ```
/// per input device:  AUHAL input unit → ChannelRingBuffer (all hw channels)
/// primary output:     AUHAL output unit render callback (the mix clock):
///                      per device: DriftCompensatingReader.pull
///                        (resamples to output rate + servo drift correction)
///                      per strip: channel map → volume (vDSP) → mix accumulate
///                      → RMS metering → planar stereo out
///                      → (if monitoring) copy post-mix bus into a ring buffer
/// monitor output:     independent AUHAL output unit render callback:
///                      DriftCompensatingReader.pull from the post-mix ring
///                      (resamples primary rate → monitor rate + drift correction)
/// ```
///
/// The primary output is the AudioMixer virtual microphone device when the
/// virtual driver is installed (so conferencing apps always get a live
/// feed), or a directly-selected hardware device otherwise. Hardware
/// monitoring, when enabled, is always a *secondary*, independently
/// clocked output fed from the same post-mix bus — never the mix clock
/// itself — so removing/losing the monitor device can never glitch the
/// virtual microphone feed.
///
/// Everything on the render path is pre-allocated at `start()`; volume and
/// routing changes are atomic writes (no graph rebuild).
@Observable
final class HALMixerEngine {
    private(set) var isRunning = false
    var lastError: String?

    enum LatencyMode: String, Codable {
        case normal
        case low
    }

    var latencyMode: LatencyMode = .normal

    // MARK: - Configuration (same shape as the legacy engine)

    struct InputConfig {
        let deviceID: AudioDeviceID
        let leftChannel: Int
        let rightChannel: Int
        var volume: Float
        var routeToMain: Bool
    }

    struct OutputConfig {
        /// The AudioMixer virtual microphone device, or `kAudioObjectUnknown`
        /// if the virtual driver isn't installed/selected. When present,
        /// this is always the primary output (the mix clock).
        let virtualDeviceID: AudioDeviceID
        /// A hardware device for monitoring the mix, or `kAudioObjectUnknown`
        /// to disable monitoring. When `virtualDeviceID` is unknown, this
        /// device is used directly as the primary output instead (hardware-only
        /// fallback for when the virtual driver isn't installed).
        let monitorDeviceID: AudioDeviceID

        init(virtualDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown), monitorDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)) {
            self.virtualDeviceID = virtualDeviceID
            self.monitorDeviceID = monitorDeviceID
        }
    }

    // MARK: - Real-time state

    /// One per unique input device.
    private final class DeviceSlot {
        let inputUnit: HALInputUnit
        let reader: DriftCompensatingReader
        /// Planar scratch receiving resampled channels each quantum.
        let scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let channelCount: Int
        let maxFrames: Int

        init(inputUnit: HALInputUnit, reader: DriftCompensatingReader, maxFrames: Int) {
            self.inputUnit = inputUnit
            self.reader = reader
            self.channelCount = inputUnit.channelCount
            self.maxFrames = maxFrames
            self.scratch = .allocate(capacity: channelCount)
            for c in 0..<channelCount {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
                p.initialize(repeating: 0, count: maxFrames)
                scratch[c] = p
            }
        }

        deinit {
            for c in 0..<channelCount { scratch[c].deallocate() }
            scratch.deallocate()
        }
    }

    /// One per input strip; parameters are atomics so the UI thread can
    /// update them while the render thread reads.
    private final class StripSlot: @unchecked Sendable {
        let stripIndex: Int
        let deviceSlot: Int
        let leftChannel: Int
        let rightChannel: Int
        let volume: Atomic<Float>
        let route: Atomic<Bool>
        let levelL = Atomic<Float>(0)
        let levelR = Atomic<Float>(0)

        init(stripIndex: Int, deviceSlot: Int, leftChannel: Int, rightChannel: Int,
             volume: Float, route: Bool) {
            self.stripIndex = stripIndex
            self.deviceSlot = deviceSlot
            self.leftChannel = leftChannel
            self.rightChannel = rightChannel
            self.volume = Atomic(volume)
            self.route = Atomic(route)
        }
    }

    /// Immutable-per-run state captured by the render callback.
    private final class RenderState: @unchecked Sendable {
        let devices: [DeviceSlot]
        let strips: [StripSlot]
        let outLevelL = Atomic<Float>(0)
        let outLevelR = Atomic<Float>(0)
        /// Post-mix bus fan-out to the monitor output, if monitoring is
        /// active. `nil` when there is no secondary monitor device — in
        /// that case the primary output IS the only consumer of the mix.
        let postMixRing: ChannelRingBuffer?
        /// 2-slot scratch reused every callback to avoid allocating an
        /// array to satisfy `ChannelRingBuffer.write`'s pointer-table API.
        let postMixPointers: UnsafeMutablePointer<UnsafePointer<Float>>?

        init(devices: [DeviceSlot], strips: [StripSlot], postMixRing: ChannelRingBuffer?) {
            self.devices = devices
            self.strips = strips
            self.postMixRing = postMixRing
            if let ring = postMixRing {
                self.postMixPointers = .allocate(capacity: ring.channelCount)
            } else {
                self.postMixPointers = nil
            }
        }

        deinit {
            postMixPointers?.deallocate()
        }
    }

    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var outputUnit: HALOutputUnit?
    /// Independent secondary output feeding a physical monitor device from
    /// the post-mix bus. `nil` when monitoring is disabled or the virtual
    /// driver isn't installed (in which case `outputUnit` targets the
    /// monitor device directly instead).
    @ObservationIgnored private var monitorOutputUnit: HALOutputUnit?
    @ObservationIgnored private var monitorReader: DriftCompensatingReader?

    private static let maxFrames = 4096
    private static let ringCapacity = 16384
    private static let normalTargetFill = 2048
    private static let lowTargetFill = 1024

    private var targetFill: Int {
        switch latencyMode {
        case .normal: Self.normalTargetFill
        case .low: Self.lowTargetFill
        }
    }

    // MARK: - Levels (polled by the UI at ~30 Hz)

    var inputLevels: [Int: (left: Float, right: Float)] {
        guard let state = renderState else { return [:] }
        var result: [Int: (left: Float, right: Float)] = [:]
        for strip in state.strips {
            result[strip.stripIndex] = (strip.levelL.load(ordering: .relaxed),
                                        strip.levelR.load(ordering: .relaxed))
        }
        return result
    }

    var outputLevel: (left: Float, right: Float) {
        guard let state = renderState else { return (0, 0) }
        return (state.outLevelL.load(ordering: .relaxed),
                state.outLevelR.load(ordering: .relaxed))
    }

    /// Diagnostics: total ring under/overruns + starved resampler pulls + current levels.
    var diagnostics: String {
        guard let state = renderState else { return "engine stopped" }
        let deviceLines = state.devices.enumerated().map { i, dev in
            "dev\(i): callbacks=\(dev.inputUnit.inputCallbackCount) fill=\(dev.reader.fillLevel) ratio=\(String(format: "%.6f", dev.reader.currentRatio)) " +
            "underruns=\(dev.inputUnit.ring.underrunCount) overruns=\(dev.inputUnit.ring.overrunCount) " +
            "starved=\(dev.reader.starvedPullCount)"
        }.joined(separator: "\n")
        let levelLines = state.strips.map { strip in
            "strip[\(strip.stripIndex)]: L=\(String(format: "%.3f", strip.levelL.load(ordering: .relaxed))) R=\(String(format: "%.3f", strip.levelR.load(ordering: .relaxed)))"
        }.joined(separator: "\n")
        let outL = state.outLevelL.load(ordering: .relaxed)
        let outR = state.outLevelR.load(ordering: .relaxed)
        var result = deviceLines + "\n" + levelLines + "\nout: L=\(String(format: "%.3f", outL)) R=\(String(format: "%.3f", outR))"
        if let ring = state.postMixRing, let reader = monitorReader {
            result += "\nmonitor: fill=\(reader.fillLevel) ratio=\(String(format: "%.6f", reader.currentRatio)) " +
                "underruns=\(ring.underrunCount) overruns=\(ring.overrunCount) starved=\(reader.starvedPullCount)"
        }
        return result
    }

    // MARK: - Lifecycle

    /// Resolves which device is the primary output (the mix clock) and
    /// which, if any, is a secondary hardware monitor fed from the post-mix
    /// bus. The virtual microphone is always primary when present; the
    /// monitor device becomes primary only as a hardware-only fallback when
    /// there's no virtual device to feed. Pure and side-effect free so it
    /// can be unit tested without touching real Core Audio devices.
    static func resolveOutputRouting(_ output: OutputConfig) -> (primary: AudioDeviceID, monitor: AudioDeviceID?) {
        guard output.virtualDeviceID != kAudioObjectUnknown else {
            return (output.monitorDeviceID, nil)
        }
        let monitor = output.monitorDeviceID != kAudioObjectUnknown ? output.monitorDeviceID : nil
        return (output.virtualDeviceID, monitor)
    }

    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()
        lastError = nil
        let targetFill = self.targetFill

        // Primary output: the virtual microphone when installed/selected,
        // otherwise the monitor device directly (hardware-only fallback).
        // Monitoring is a secondary output only when the virtual device is
        // primary; if there's no virtual device, "monitoring" IS the primary
        // output, so there is nothing further to fan out to.
        let (primaryDeviceID, secondaryMonitorDeviceID) = Self.resolveOutputRouting(output)

        log("start() — primary=\(primaryDeviceID), monitor=\(secondaryMonitorDeviceID.map(String.init) ?? "none"), \(inputs.count) inputs, latency=\(latencyMode.rawValue), targetFill=\(targetFill)")

        guard primaryDeviceID != kAudioObjectUnknown else {
            log("⏭️ No output device, skipping")
            return
        }

        let outputRate = HALDeviceInfo.nominalSampleRate(deviceID: primaryDeviceID)
        guard outputRate > 0 else {
            throw HALUnitError.osStatus("Output device sample rate is 0", -1)
        }

        // Group active strips by device.
        var deviceOrder: [AudioDeviceID] = []
        var deviceStrips: [AudioDeviceID: [(index: Int, config: InputConfig)]] = [:]
        for (index, input) in inputs.enumerated() {
            guard input.deviceID != kAudioObjectUnknown else { continue }
            if deviceStrips[input.deviceID] == nil { deviceOrder.append(input.deviceID) }
            deviceStrips[input.deviceID, default: []].append((index, input))
        }

        // Build device slots (input units + drift readers).
        var devices: [DeviceSlot] = []
        var strips: [StripSlot] = []
        for (slotIndex, deviceID) in deviceOrder.enumerated() {
            let inputUnit = try HALInputUnit(deviceID: deviceID,
                                             ringCapacity: Self.ringCapacity,
                                             maxFrames: Self.maxFrames)
            inputUnit.ring.prefillSilence(frames: targetFill)
            let reader = DriftCompensatingReader(ring: inputUnit.ring,
                                                 inputRate: inputUnit.sampleRate,
                                                 outputRate: outputRate,
                                                 targetFill: targetFill,
                                                 maxQuantum: Self.maxFrames)
            devices.append(DeviceSlot(inputUnit: inputUnit, reader: reader, maxFrames: Self.maxFrames))
            log("Device \(deviceID): \(inputUnit.channelCount)ch @ \(inputUnit.sampleRate) Hz → \(outputRate) Hz")

            for (index, config) in deviceStrips[deviceID] ?? [] {
                strips.append(StripSlot(stripIndex: index,
                                        deviceSlot: slotIndex,
                                        leftChannel: config.leftChannel,
                                        rightChannel: config.rightChannel,
                                        volume: config.volume,
                                        route: config.routeToMain))
                log("  Strip[\(index)]: L=ch\(config.leftChannel) R=ch\(config.rightChannel), vol=\(config.volume), route=\(config.routeToMain)")
            }
        }

        // Post-mix fan-out ring, only allocated when there's a secondary
        // monitor to feed. Prefilled with silence so the monitor's reader
        // has a jitter cushion the instant it starts pulling.
        let postMixRing: ChannelRingBuffer? = secondaryMonitorDeviceID != nil
            ? ChannelRingBuffer(channelCount: 2, capacity: Self.ringCapacity) : nil
        postMixRing?.prefillSilence(frames: targetFill)

        let state = RenderState(devices: devices, strips: strips, postMixRing: postMixRing)
        self.renderState = state

        do {
            // Primary output unit with the mix handler. The handler captures
            // only `state` (a final class); all buffers inside are pre-allocated.
            let outputUnit = try HALOutputUnit(deviceID: primaryDeviceID,
                                               maxFrames: Self.maxFrames) { dest, frameCount in
                HALMixerEngine.mix(state: state, dest: dest, frameCount: frameCount)
            }
            self.outputUnit = outputUnit

            // Start inputs first so data is flowing, then the primary output.
            for device in devices {
                try device.inputUnit.start()
            }
            try outputUnit.start()
        } catch {
            // Roll back: stop any units already started before rethrowing.
            stop()
            throw error
        }

        isRunning = true
        log("✅ Engine running (primary output rate \(outputRate) Hz)")

        // Secondary monitor output: independently clocked, fed from the
        // post-mix ring via its own drift-compensating reader. This is
        // strictly best-effort — if the monitor device fails to start, the
        // primary (virtual microphone) output keeps running unaffected.
        if let monitorDeviceID = secondaryMonitorDeviceID, let ring = postMixRing {
            do {
                let monitorRate = HALDeviceInfo.nominalSampleRate(deviceID: monitorDeviceID)
                guard monitorRate > 0 else {
                    throw HALUnitError.osStatus("Monitor device sample rate is 0", -1)
                }
                let reader = DriftCompensatingReader(ring: ring,
                                                     inputRate: outputRate,
                                                     outputRate: monitorRate,
                                                     targetFill: targetFill,
                                                     maxQuantum: Self.maxFrames)
                self.monitorReader = reader
                let monitorOutputUnit = try HALOutputUnit(deviceID: monitorDeviceID,
                                                          maxFrames: Self.maxFrames) { dest, frameCount in
                    reader.pull(into: dest, frameCount: frameCount)
                }
                try monitorOutputUnit.start()
                self.monitorOutputUnit = monitorOutputUnit
                log("✅ Monitor output running (device \(monitorDeviceID), rate \(monitorRate) Hz)")
            } catch {
                log("⚠️ Monitor output failed to start, continuing without hardware monitoring: \(error)")
                monitorOutputUnit?.stop()
                monitorOutputUnit = nil
                monitorReader = nil
            }
        }
    }

    func stop() {
        monitorOutputUnit?.stop()
        monitorOutputUnit = nil
        monitorReader = nil
        outputUnit?.stop()
        outputUnit = nil
        if let state = renderState {
            for device in state.devices {
                device.inputUnit.stop()
            }
        }
        renderState = nil
        isRunning = false
    }

    // MARK: - Live parameter changes (no rebuild)

    func setVolume(_ volume: Float, forInput index: Int) {
        guard let state = renderState else { return }
        for strip in state.strips where strip.stripIndex == index {
            strip.volume.store(volume, ordering: .relaxed)
        }
    }

    func setRouteToMain(_ enabled: Bool, forInput index: Int) {
        guard let state = renderState else { return }
        for strip in state.strips where strip.stripIndex == index {
            strip.route.store(enabled, ordering: .relaxed)
        }
    }

    // MARK: - Render-thread mix (static: no self capture)

    private static func mix(state: RenderState,
                            dest: UnsafePointer<UnsafeMutablePointer<Float>>,
                            frameCount: Int) {
        let n = frameCount
        let byteCount = n * MemoryLayout<Float>.size
        memset(dest[0], 0, byteCount)
        memset(dest[1], 0, byteCount)
        guard n > 0, n <= HALMixerEngine.maxFrames else { return }

        // 1. Pull each device once: resampled, drift-corrected planar channels.
        for device in state.devices {
            device.reader.pull(into: UnsafePointer(device.scratch), frameCount: n)
        }

        // 2. Per strip: channel map → volume → accumulate into the mix bus.
        for strip in state.strips {
            let device = state.devices[strip.deviceSlot]
            let lIdx = strip.leftChannel
            let rIdx = strip.rightChannel
            let srcL: UnsafeMutablePointer<Float>? = lIdx < device.channelCount ? device.scratch[lIdx] : nil
            let srcR: UnsafeMutablePointer<Float>? = rIdx < device.channelCount ? device.scratch[rIdx] : nil

            var vol = strip.volume.load(ordering: .relaxed)
            let routed = strip.route.load(ordering: .relaxed)

            // Metering is pre-fader/pre-route so the meter moves even when
            // the strip is muted from the mix.
            var msL: Float = 0
            var msR: Float = 0
            if let srcL { vDSP_measqv(srcL, 1, &msL, vDSP_Length(n)) }
            if let srcR { vDSP_measqv(srcR, 1, &msR, vDSP_Length(n)) }
            strip.levelL.store(min(1, sqrt(msL) * 2), ordering: .relaxed)
            strip.levelR.store(min(1, sqrt(msR) * 2), ordering: .relaxed)

            if routed, vol > 0 {
                if let srcL { vDSP_vsma(srcL, 1, &vol, dest[0], 1, dest[0], 1, vDSP_Length(n)) }
                if let srcR { vDSP_vsma(srcR, 1, &vol, dest[1], 1, dest[1], 1, vDSP_Length(n)) }
            }
        }

        // 3. Soft clip guard + output metering.
        var lo: Float = -1
        var hi: Float = 1
        vDSP_vclip(dest[0], 1, &lo, &hi, dest[0], 1, vDSP_Length(n))
        vDSP_vclip(dest[1], 1, &lo, &hi, dest[1], 1, vDSP_Length(n))

        var msL: Float = 0
        var msR: Float = 0
        vDSP_measqv(dest[0], 1, &msL, vDSP_Length(n))
        vDSP_measqv(dest[1], 1, &msR, vDSP_Length(n))
        state.outLevelL.store(min(1, sqrt(msL) * 2), ordering: .relaxed)
        state.outLevelR.store(min(1, sqrt(msR) * 2), ordering: .relaxed)

        // 4. Fan out the finished post-mix bus to the monitor ring, if a
        // secondary monitor output is active. `postMixPointers` is
        // pre-allocated scratch reused every callback — only pointer
        // assignment happens here, no allocation.
        if let ring = state.postMixRing, let pointers = state.postMixPointers {
            pointers[0] = UnsafePointer(dest[0])
            pointers[1] = UnsafePointer(dest[1])
            ring.write(channelPointers: UnsafePointer(pointers), count: n)
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
