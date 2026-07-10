import Foundation
import Accelerate
import CoreAudio
import Synchronization

/// AUHAL-based mixer engine (LadioCast-style architecture).
///
/// Signal path:
/// ```
/// per input device:  AUHAL input unit → ChannelRingBuffer (all hw channels)
/// output device:     AUHAL output unit render callback:
///                      per device: DriftCompensatingReader.pull
///                        (resamples to output rate + servo drift correction)
///                      per strip: channel map → volume (vDSP) → mix accumulate
///                      → RMS metering → planar stereo out
/// ```
///
/// Everything on the render path is pre-allocated at `start()`; volume and
/// routing changes are atomic writes (no graph rebuild).
@Observable
final class HALMixerEngine {
    private(set) var isRunning = false
    var lastError: String?

    // MARK: - Configuration (same shape as the legacy engine)

    struct InputConfig {
        let deviceID: AudioDeviceID
        let leftChannel: Int
        let rightChannel: Int
        var volume: Float
        var routeToMain: Bool
    }

    struct OutputConfig {
        let deviceID: AudioDeviceID
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

        init(devices: [DeviceSlot], strips: [StripSlot]) {
            self.devices = devices
            self.strips = strips
        }
    }

    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var outputUnit: HALOutputUnit?

    private static let maxFrames = 4096
    private static let ringCapacity = 16384
    private static let targetFill = 2048

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

    /// Diagnostics: total ring under/overruns + starved resampler pulls.
    var diagnostics: String {
        guard let state = renderState else { return "engine stopped" }
        return state.devices.enumerated().map { i, dev in
            "dev\(i): callbacks=\(dev.inputUnit.inputCallbackCount) fill=\(dev.reader.fillLevel) ratio=\(String(format: "%.6f", dev.reader.currentRatio)) " +
            "underruns=\(dev.inputUnit.ring.underrunCount) overruns=\(dev.inputUnit.ring.overrunCount) " +
            "starved=\(dev.reader.starvedPullCount)"
        }.joined(separator: "\n")
    }

    // MARK: - Lifecycle

    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()
        lastError = nil

        log("start() — output=\(output.deviceID), \(inputs.count) inputs")

        guard output.deviceID != kAudioObjectUnknown else {
            log("⏭️ No output device, skipping")
            return
        }

        let outputRate = HALDeviceInfo.nominalSampleRate(deviceID: output.deviceID)
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
            inputUnit.ring.prefillSilence(frames: Self.targetFill)
            let reader = DriftCompensatingReader(ring: inputUnit.ring,
                                                 inputRate: inputUnit.sampleRate,
                                                 outputRate: outputRate,
                                                 targetFill: Self.targetFill,
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

        let state = RenderState(devices: devices, strips: strips)
        self.renderState = state

        do {
            // Output unit with the mix handler. The handler captures only `state`
            // (a final class); all buffers inside are pre-allocated.
            let outputUnit = try HALOutputUnit(deviceID: output.deviceID,
                                               maxFrames: Self.maxFrames) { dest, frameCount in
                HALMixerEngine.mix(state: state, dest: dest, frameCount: frameCount)
            }
            self.outputUnit = outputUnit

            // Start inputs first so data is flowing, then the output.
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
        log("✅ Engine running (output rate \(outputRate) Hz)")
    }

    func stop() {
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
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("[HALMixerEngine] \(message)")
    }
}
