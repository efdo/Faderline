import Foundation
import Accelerate
import CoreAudio
import Synchronization
import OSLog

private let logger = Logger(subsystem: "com.faderline", category: "HALMixerEngine")

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
        /// Balance/pan in `[-1, +1]`; 0 is center. See `FaderTaper.panGains(_:)`.
        var pan: Float = 0
        var mute: Bool = false
        var solo: Bool = false
    }

    struct OutputConfig {
        let deviceID: AudioDeviceID
        /// Master linear gain applied to the mix bus (see `FaderTaper.gain(forDB:)`).
        var volume: Float = 1.0
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
        /// Pre-resolved constant-power pan gains (see `FaderTaper.panGains(_:)`).
        /// Resolved off the render thread — the callback only ever reads two floats.
        let panL: Atomic<Float>
        let panR: Atomic<Float>
        let mute: Atomic<Bool>
        let solo: Atomic<Bool>
        let levelL = Atomic<Float>(0)
        let levelR = Atomic<Float>(0)
        /// Running peak (max magnitude) since the last UI drain via `exchange(0, ...)`.
        let peakL = Atomic<Float>(0)
        let peakR = Atomic<Float>(0)

        init(stripIndex: Int, deviceSlot: Int, leftChannel: Int, rightChannel: Int,
             volume: Float, route: Bool, pan: Float, mute: Bool, solo: Bool) {
            self.stripIndex = stripIndex
            self.deviceSlot = deviceSlot
            self.leftChannel = leftChannel
            self.rightChannel = rightChannel
            self.volume = Atomic(volume)
            self.route = Atomic(route)
            let panGains = FaderTaper.panGains(pan)
            self.panL = Atomic(panGains.left)
            self.panR = Atomic(panGains.right)
            self.mute = Atomic(mute)
            self.solo = Atomic(solo)
        }
    }

    /// Immutable-per-run state captured by the render callback.
    private final class RenderState: @unchecked Sendable {
        let devices: [DeviceSlot]
        let strips: [StripSlot]
        let outLevelL = Atomic<Float>(0)
        let outLevelR = Atomic<Float>(0)
        /// Running peak (max magnitude) since the last UI drain, measured
        /// *before* the soft-clip guard so >= 1.0 means a genuine over.
        let outPeakL = Atomic<Float>(0)
        let outPeakR = Atomic<Float>(0)
        /// True while any strip is soloed; non-soloed strips go silent (but
        /// keep metering) rather than being rebuilt out of the graph.
        let anySolo: Atomic<Bool>
        let outGain: Atomic<Float>
        let outMute = Atomic<Bool>(false)

        init(devices: [DeviceSlot], strips: [StripSlot], outputVolume: Float) {
            self.devices = devices
            self.strips = strips
            let pairs = strips.map {
                (routed: $0.route.load(ordering: .relaxed), soloed: $0.solo.load(ordering: .relaxed))
            }
            self.anySolo = Atomic(HALMixerEngine.anySoloed(among: pairs))
            self.outGain = Atomic(outputVolume)
        }
    }

    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var outputUnit: HALOutputUnit?

    private static let maxFrames = 4096
    private static let ringCapacity = 16384
    private static let normalTargetFill = 2048
    private static let lowTargetFill = 1024
    #if DEBUG
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    #endif

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

    /// Peak (max magnitude) since the last call, per strip. Drained via atomic
    /// `exchange(0, ...)`: the render thread is the sole writer of a running
    /// max, and this is the sole resetting reader, so the only possible race
    /// loses at most one render quantum's peak sample — an acceptable
    /// trade-off to stay lock-free on the render thread.
    var inputPeaks: [Int: (left: Float, right: Float)] {
        guard let state = renderState else { return [:] }
        var result: [Int: (left: Float, right: Float)] = [:]
        for strip in state.strips {
            let l = strip.peakL.exchange(0, ordering: .relaxed)
            let r = strip.peakR.exchange(0, ordering: .relaxed)
            result[strip.stripIndex] = (l, r)
        }
        return result
    }

    /// Output bus peak since the last call. Measured *before* the soft-clip
    /// guard in `mix()`, so a drained value `>= 1.0` (0 dBFS) means the mix
    /// genuinely clipped, not merely that the limiter engaged.
    var outputPeak: (left: Float, right: Float) {
        guard let state = renderState else { return (0, 0) }
        return (state.outPeakL.exchange(0, ordering: .relaxed),
                state.outPeakR.exchange(0, ordering: .relaxed))
    }

    /// Diagnostics: total ring under/overruns + starved resampler pulls + current levels.
    var diagnostics: String {
        guard let state = renderState else { return "engine stopped" }
        let deviceLines = state.devices.enumerated().map { i, dev in
            #if DEBUG
            let inputCallbacks = dev.inputUnit.inputCallbackCount
            let avgInputUS = Self.microseconds(
                ticks: inputCallbacks > 0 ? dev.inputUnit.inputCallbackTicks / inputCallbacks : 0
            )
            let maxInputUS = Self.microseconds(ticks: dev.inputUnit.maxInputCallbackTicks)
            let inputTiming = " inputAvgUS=\(String(format: "%.1f", avgInputUS)) inputMaxUS=\(String(format: "%.1f", maxInputUS))"
            #else
            let inputTiming = ""
            #endif
            return "dev\(i): callbacks=\(dev.inputUnit.inputCallbackCount) fill=\(dev.reader.fillLevel) ratio=\(String(format: "%.6f", dev.reader.currentRatio)) " +
            "underruns=\(dev.inputUnit.ring.underrunCount) overruns=\(dev.inputUnit.ring.overrunCount) " +
            "starved=\(dev.reader.starvedPullCount) skipped=\(dev.reader.skippedFrameCount)" + inputTiming
        }.joined(separator: "\n")
        let levelLines = state.strips.map { strip in
            "strip[\(strip.stripIndex)]: L=\(String(format: "%.3f", strip.levelL.load(ordering: .relaxed))) R=\(String(format: "%.3f", strip.levelR.load(ordering: .relaxed))) " +
            "peakL=\(String(format: "%.3f", strip.peakL.load(ordering: .relaxed))) peakR=\(String(format: "%.3f", strip.peakR.load(ordering: .relaxed))) " +
            "mute=\(strip.mute.load(ordering: .relaxed)) solo=\(strip.solo.load(ordering: .relaxed)) " +
            "panL=\(String(format: "%.3f", strip.panL.load(ordering: .relaxed))) panR=\(String(format: "%.3f", strip.panR.load(ordering: .relaxed)))"
        }.joined(separator: "\n")
        let outL = state.outLevelL.load(ordering: .relaxed)
        let outR = state.outLevelR.load(ordering: .relaxed)
        let outPeakL = state.outPeakL.load(ordering: .relaxed)
        let outPeakR = state.outPeakR.load(ordering: .relaxed)
        let outputDiagnostics: String
        if let outputUnit {
            #if DEBUG
            let outputCallbacks = outputUnit.renderCallbackCount
            let avgOutputUS = Self.microseconds(
                ticks: outputCallbacks > 0 ? outputUnit.renderHandlerTicks / outputCallbacks : 0
            )
            let maxOutputUS = Self.microseconds(ticks: outputUnit.maxRenderHandlerTicks)
            outputDiagnostics = "output: callbacks=\(outputCallbacks) lastFrames=\(outputUnit.lastRenderFrameCount) maxFrames=\(outputUnit.maxRenderFrameCount) " +
                "mixAvgUS=\(String(format: "%.1f", avgOutputUS)) mixMaxUS=\(String(format: "%.1f", maxOutputUS))"
            #else
            outputDiagnostics = "output: callbacks=\(outputUnit.renderCallbackCount) lastFrames=\(outputUnit.lastRenderFrameCount) maxFrames=\(outputUnit.maxRenderFrameCount)"
            #endif
        } else {
            outputDiagnostics = "output: stopped"
        }
        return deviceLines + "\n" + levelLines +
            "\n" + outputDiagnostics +
            "\nout: L=\(String(format: "%.3f", outL)) R=\(String(format: "%.3f", outR)) " +
            "peakL=\(String(format: "%.3f", outPeakL)) peakR=\(String(format: "%.3f", outPeakR)) " +
            "mute=\(state.outMute.load(ordering: .relaxed)) gain=\(String(format: "%.3f", state.outGain.load(ordering: .relaxed)))"
    }

    // MARK: - Lifecycle

    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()
        lastError = nil
        let targetFill = self.targetFill

        log("start() — output=\(output.deviceID), \(inputs.count) inputs, latency=\(latencyMode.rawValue), targetFill=\(targetFill)")

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
                                        route: config.routeToMain,
                                        pan: config.pan,
                                        mute: config.mute,
                                        solo: config.solo))
                log("  Strip[\(index)]: L=ch\(config.leftChannel) R=ch\(config.rightChannel), vol=\(config.volume), route=\(config.routeToMain), pan=\(config.pan), mute=\(config.mute), solo=\(config.solo)")
            }
        }

        let state = RenderState(devices: devices, strips: strips, outputVolume: output.volume)
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
        // Un/re-routing a strip can change whether its solo flag "counts" —
        // see `anySoloed(among:)`.
        recomputeAnySolo(state)
    }

    /// Sets a strip's pan/balance. The pan law's `cos`/`sin` are computed here
    /// on the calling (UI) thread; the render thread only ever reads two
    /// pre-resolved atomics (`panL`/`panR`).
    func setPan(_ pan: Float, forInput index: Int) {
        guard let state = renderState else { return }
        let gains = FaderTaper.panGains(pan)
        for strip in state.strips where strip.stripIndex == index {
            strip.panL.store(gains.left, ordering: .relaxed)
            strip.panR.store(gains.right, ordering: .relaxed)
        }
    }

    func setMute(_ muted: Bool, forInput index: Int) {
        guard let state = renderState else { return }
        for strip in state.strips where strip.stripIndex == index {
            strip.mute.store(muted, ordering: .relaxed)
        }
    }

    /// Sets a strip's solo state and recomputes whether *any* strip is
    /// soloed. When any strip is soloed, only soloed strips are audible;
    /// this mirrors standard console solo-in-place behavior.
    func setSolo(_ soloed: Bool, forInput index: Int) {
        guard let state = renderState else { return }
        for strip in state.strips where strip.stripIndex == index {
            strip.solo.store(soloed, ordering: .relaxed)
        }
        recomputeAnySolo(state)
    }

    private func recomputeAnySolo(_ state: RenderState) {
        let pairs = state.strips.map {
            (routed: $0.route.load(ordering: .relaxed), soloed: $0.solo.load(ordering: .relaxed))
        }
        state.anySolo.store(Self.anySoloed(among: pairs), ordering: .relaxed)
    }

    /// Pure solo-in-place gating logic, factored out (and left internal, not
    /// private) for direct unit testing. A soloed-but-unrouted strip must
    /// NOT count: it is itself inaudible either way (not routed), so letting
    /// it count would silence every other, properly-routed strip too —
    /// turning "solo this channel" into "mute everything" instead of
    /// isolating the soloed channel.
    static func anySoloed(among strips: [(routed: Bool, soloed: Bool)]) -> Bool {
        strips.contains { $0.routed && $0.soloed }
    }

    func setOutputVolume(_ gain: Float) {
        guard let state = renderState else { return }
        state.outGain.store(gain, ordering: .relaxed)
    }

    func setOutputMuted(_ muted: Bool) {
        guard let state = renderState else { return }
        state.outMute.store(muted, ordering: .relaxed)
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

        let anySolo = state.anySolo.load(ordering: .relaxed)

        // 2. Per strip: channel map → pan → volume → accumulate into the mix bus.
        for strip in state.strips {
            let device = state.devices[strip.deviceSlot]
            let lIdx = strip.leftChannel
            let rIdx = strip.rightChannel
            let srcL: UnsafeMutablePointer<Float>? = lIdx < device.channelCount ? device.scratch[lIdx] : nil
            let srcR: UnsafeMutablePointer<Float>? = rIdx < device.channelCount ? device.scratch[rIdx] : nil

            let vol = strip.volume.load(ordering: .relaxed)
            let routed = strip.route.load(ordering: .relaxed)
            let muted = strip.mute.load(ordering: .relaxed)
            let soloed = strip.solo.load(ordering: .relaxed)
            // Solo-in-place: when any strip is soloed, only soloed strips reach the bus.
            let audible = routed && !muted && (!anySolo || soloed)

            // Metering is pre-fader/pre-pan/pre-route so it shows the raw
            // source (useful for gain-staging) and still moves even when muted.
            var msL: Float = 0
            var msR: Float = 0
            var peakBlockL: Float = 0
            var peakBlockR: Float = 0
            if let srcL {
                vDSP_measqv(srcL, 1, &msL, vDSP_Length(n))
                vDSP_maxmgv(srcL, 1, &peakBlockL, vDSP_Length(n))
            }
            if let srcR {
                vDSP_measqv(srcR, 1, &msR, vDSP_Length(n))
                vDSP_maxmgv(srcR, 1, &peakBlockR, vDSP_Length(n))
            }
            strip.levelL.store(sqrt(msL), ordering: .relaxed)
            strip.levelR.store(sqrt(msR), ordering: .relaxed)
            // Running max; drained (and reset) by the UI via `exchange(0, ...)`.
            if peakBlockL > strip.peakL.load(ordering: .relaxed) {
                strip.peakL.store(peakBlockL, ordering: .relaxed)
            }
            if peakBlockR > strip.peakR.load(ordering: .relaxed) {
                strip.peakR.store(peakBlockR, ordering: .relaxed)
            }

            if audible, vol > 0 {
                var volL = vol * strip.panL.load(ordering: .relaxed)
                var volR = vol * strip.panR.load(ordering: .relaxed)
                if let srcL { vDSP_vsma(srcL, 1, &volL, dest[0], 1, dest[0], 1, vDSP_Length(n)) }
                if let srcR { vDSP_vsma(srcR, 1, &volR, dest[1], 1, dest[1], 1, vDSP_Length(n)) }
            }
        }

        // 3. Master gain/mute, then peak (measured *before* the soft-clip
        // guard so >= 1.0 means a genuine over), then the clip guard itself,
        // then post-limiter RMS metering.
        let outMuted = state.outMute.load(ordering: .relaxed)
        var outGain = outMuted ? 0 : state.outGain.load(ordering: .relaxed)
        if outGain != 1.0 {
            vDSP_vsmul(dest[0], 1, &outGain, dest[0], 1, vDSP_Length(n))
            vDSP_vsmul(dest[1], 1, &outGain, dest[1], 1, vDSP_Length(n))
        }

        var outPeakBlockL: Float = 0
        var outPeakBlockR: Float = 0
        vDSP_maxmgv(dest[0], 1, &outPeakBlockL, vDSP_Length(n))
        vDSP_maxmgv(dest[1], 1, &outPeakBlockR, vDSP_Length(n))
        if outPeakBlockL > state.outPeakL.load(ordering: .relaxed) {
            state.outPeakL.store(outPeakBlockL, ordering: .relaxed)
        }
        if outPeakBlockR > state.outPeakR.load(ordering: .relaxed) {
            state.outPeakR.store(outPeakBlockR, ordering: .relaxed)
        }

        var lo: Float = -1
        var hi: Float = 1
        vDSP_vclip(dest[0], 1, &lo, &hi, dest[0], 1, vDSP_Length(n))
        vDSP_vclip(dest[1], 1, &lo, &hi, dest[1], 1, vDSP_Length(n))

        var msL: Float = 0
        var msR: Float = 0
        vDSP_measqv(dest[0], 1, &msL, vDSP_Length(n))
        vDSP_measqv(dest[1], 1, &msR, vDSP_Length(n))
        state.outLevelL.store(sqrt(msL), ordering: .relaxed)
        state.outLevelR.store(sqrt(msR), ordering: .relaxed)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    #if DEBUG
    private static func microseconds(ticks: Int) -> Double {
        let nanos = Double(ticks) * Double(machTimebase.numer) / Double(machTimebase.denom)
        return nanos / 1_000
    }
    #endif
}
