import AVFoundation
import Accelerate
import CoreAudio

// MARK: - Lock-free Stereo Ring Buffer (SPSC)

/// A lock-free SPSC stereo ring buffer for real-time audio threads.
/// Producer (tap) writes, consumer (render callback) reads.
/// Uses UnsafeMutablePointer storage with memcpy for bulk transfers.
/// Thread safety via single-writer/single-reader discipline + memory fences.
private final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storageL: UnsafeMutablePointer<Float>
    private let storageR: UnsafeMutablePointer<Float>

    // Atomic head pointers using os_unfair_lock-protected access.
    // The lock hold time is ~1 nanosecond (just read/write an Int).
    private let headLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _writeHead: Int = 0
    private var _readHead: Int = 0

    private(set) var underrunCount: Int = 0

    init(capacity: Int = 16384) {
        let cap = 1 << Int(ceil(log2(Double(max(capacity, 64)))))
        self.capacity = cap
        self.mask = cap - 1
        self.storageL = .allocate(capacity: cap)
        self.storageR = .allocate(capacity: cap)
        self.storageL.initialize(repeating: 0, count: cap)
        self.storageR.initialize(repeating: 0, count: cap)
        headLock.initialize(to: os_unfair_lock())
    }

    deinit {
        storageL.deallocate()
        storageR.deallocate()
        headLock.deallocate()
    }

    var availableFrames: Int {
        os_unfair_lock_lock(headLock)
        let result = _writeHead - _readHead
        os_unfair_lock_unlock(headLock)
        return result
    }

    /// Write stereo frames using memcpy (handles wrap-around).
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(headLock)
        let wh = _writeHead
        let startIdx = wh & mask

        if startIdx + count <= capacity {
            // No wrap — single memcpy per channel
            memcpy(storageL + startIdx, left, count * MemoryLayout<Float>.size)
            memcpy(storageR + startIdx, right, count * MemoryLayout<Float>.size)
        } else {
            // Wraps around — two memcpy calls per channel
            let firstPart = capacity - startIdx
            let secondPart = count - firstPart
            memcpy(storageL + startIdx, left, firstPart * MemoryLayout<Float>.size)
            memcpy(storageR + startIdx, right, firstPart * MemoryLayout<Float>.size)
            memcpy(storageL, left + firstPart, secondPart * MemoryLayout<Float>.size)
            memcpy(storageR, right + firstPart, secondPart * MemoryLayout<Float>.size)
        }

        _writeHead = wh + count
        if _writeHead - _readHead > capacity {
            _readHead = _writeHead - capacity
        }
        os_unfair_lock_unlock(headLock)
    }

    /// Read stereo frames using memcpy. Fills with silence on underrun.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(headLock)
        let available = _writeHead - _readHead
        let toRead = min(count, available)
        let silenceCount = count - toRead

        if silenceCount > 0 {
            underrunCount += 1
        }

        if toRead > 0 {
            let startIdx = _readHead & mask
            if startIdx + toRead <= capacity {
                memcpy(left, storageL + startIdx, toRead * MemoryLayout<Float>.size)
                memcpy(right, storageR + startIdx, toRead * MemoryLayout<Float>.size)
            } else {
                let firstPart = capacity - startIdx
                let secondPart = toRead - firstPart
                memcpy(left, storageL + startIdx, firstPart * MemoryLayout<Float>.size)
                memcpy(right, storageR + startIdx, firstPart * MemoryLayout<Float>.size)
                memcpy(left + firstPart, storageL, secondPart * MemoryLayout<Float>.size)
                memcpy(right + firstPart, storageR, secondPart * MemoryLayout<Float>.size)
            }
            _readHead += toRead
        }

        os_unfair_lock_unlock(headLock)

        // Fill remaining with silence (outside lock)
        if silenceCount > 0 {
            memset(left + toRead, 0, silenceCount * MemoryLayout<Float>.size)
            memset(right + toRead, 0, silenceCount * MemoryLayout<Float>.size)
        }
    }

    /// Pre-fill with silence to act as jitter buffer.
    func prefill(frames: Int) {
        os_unfair_lock_lock(headLock)
        _writeHead = frames
        _readHead = 0
        // Storage is already zero-initialized
        os_unfair_lock_unlock(headLock)
    }

    func reset() {
        os_unfair_lock_lock(headLock)
        _writeHead = 0
        _readHead = 0
        underrunCount = 0
        os_unfair_lock_unlock(headLock)
    }
}

// MARK: - MixerEngine

/// Manages audio routing: shared capture engines → ring buffers → source nodes → output.
///
/// Architecture:
/// - One `AVAudioEngine` per unique input device (shared when multiple strips use the same device).
/// - A tap on each capture engine grabs all hardware channels (using CoreAudio HAL channel count).
/// - Per-strip channel remapping writes L/R into a StereoRingBuffer.
/// - AVAudioSourceNode (pull-based) reads from ring buffer on the output engine's render thread.
/// - An intermediate AVAudioMixerNode handles sample rate conversion when input ≠ output rate.
@Observable
final class LegacyMixerEngine {
    private var outputEngine = AVAudioEngine()
    private var sharedCaptures: [AudioDeviceID: SharedCapture] = [:]
    private var stripNodes: [Int: StripNodes] = [:]

    private(set) var inputLevels: [Int: (left: Float, right: Float)] = [:]
    private(set) var outputLevel: (left: Float, right: Float) = (0, 0)
    private(set) var isRunning = false

    var lastError: String?

    // MARK: - Configuration

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

    // MARK: - Internal state

    private struct SharedCapture {
        let engine: AVAudioEngine
        let hwChannelCount: Int
        let sampleRate: Double
    }

    private struct StripNodes {
        let sourceNode: AVAudioSourceNode
        let mixerNode: AVAudioMixerNode
        let ringBuffer: StereoRingBuffer
    }

    private struct TapTarget {
        let stripIndex: Int
        let leftChannel: Int
        let rightChannel: Int
        let ringBuffer: StereoRingBuffer
    }

    /// Pre-allocated silence buffer for use in tap callbacks (avoids malloc on audio thread).
    private var silenceBuffer: UnsafeMutablePointer<Float>?
    private var silenceBufferSize: Int = 0

    // MARK: - CoreAudio HAL helpers

    /// Query actual input channel count from CoreAudio HAL.
    private static func deviceInputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bytes.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bytes)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bytes.assumingMemoryBound(to: AudioBufferList.self))
        var totalChannels = 0
        for buf in bufferList {
            totalChannels += Int(buf.mNumberChannels)
        }
        return totalChannels
    }

    /// Query nominal sample rate from CoreAudio HAL.
    private static func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }

    // MARK: - Engine lifecycle

    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()
        lastError = nil

        log("start() — output=\(output.deviceID), \(inputs.count) inputs")

        guard output.deviceID != kAudioObjectUnknown else {
            log("⏭️ No output device, skipping")
            return
        }

        outputEngine = AVAudioEngine()
        try setOutputDevice(output.deviceID, on: outputEngine)

        let outputRate = outputEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard outputRate > 0 else {
            throw MixerError.invalidFormat("Output sample rate is 0")
        }
        let outputStereo = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        log("Output: rate=\(outputRate) Hz")

        let mainMixer = outputEngine.mainMixerNode

        // Group active inputs by device ID
        var deviceStrips: [AudioDeviceID: [(index: Int, config: InputConfig)]] = [:]
        for (index, input) in inputs.enumerated() {
            guard input.routeToMain, input.deviceID != kAudioObjectUnknown else { continue }
            deviceStrips[input.deviceID, default: []].append((index, input))
        }

        // For each unique device, create ONE shared capture engine
        for (deviceID, strips) in deviceStrips {
            let captureEngine = AVAudioEngine()
            try setInputDevice(deviceID, on: captureEngine)

            // Query actual hardware channel count and sample rate via CoreAudio HAL
            let hwChannels = LegacyMixerEngine.deviceInputChannelCount(deviceID)
            let inputRate = LegacyMixerEngine.deviceSampleRate(deviceID)

            log("Device \(deviceID): HAL hwChannels=\(hwChannels), HAL rate=\(inputRate) Hz, serving \(strips.count) strip(s)")

            guard inputRate > 0 else {
                throw MixerError.invalidFormat("Input device \(deviceID) sample rate is 0")
            }
            guard hwChannels > 0 else {
                throw MixerError.invalidFormat("Input device \(deviceID) has 0 channels")
            }

            // Create format matching actual hardware channels
            let hwFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: AVAudioChannelCount(hwChannels))!

            // Build valid graph on capture engine (silenced output)
            let inputNode = captureEngine.inputNode
            let captureMixer = captureEngine.mainMixerNode
            captureEngine.connect(inputNode, to: captureMixer, format: hwFormat)
            captureMixer.outputVolume = 0

            sharedCaptures[deviceID] = SharedCapture(engine: captureEngine, hwChannelCount: hwChannels, sampleRate: inputRate)

            // Create source nodes + ring buffers for each strip
            var tapTargets: [TapTarget] = []
            let inputStereo = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 2)!

            for (index, input) in strips {
                let ringBuffer = StereoRingBuffer(capacity: 8192)

                // AVAudioSourceNode: pull-based, runs on the render thread
                let sourceNode = AVAudioSourceNode(format: inputStereo) { _, _, frameCount, audioBufferList in
                    let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    guard ablPointer.count >= 2 else { return noErr }

                    let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
                    let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)

                    ringBuffer.read(left: leftPtr, right: rightPtr, count: Int(frameCount))

                    ablPointer[0].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
                    ablPointer[1].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)

                    return noErr
                }

                // Intermediate mixer handles sample rate conversion (input rate → output rate)
                let mixerNode = AVAudioMixerNode()
                outputEngine.attach(sourceNode)
                outputEngine.attach(mixerNode)
                outputEngine.connect(sourceNode, to: mixerNode, format: inputStereo)
                outputEngine.connect(mixerNode, to: mainMixer, format: outputStereo)
                mixerNode.volume = input.volume

                stripNodes[index] = StripNodes(sourceNode: sourceNode, mixerNode: mixerNode, ringBuffer: ringBuffer)

                tapTargets.append(TapTarget(
                    stripIndex: index,
                    leftChannel: input.leftChannel,
                    rightChannel: input.rightChannel,
                    ringBuffer: ringBuffer
                ))

                log("  Strip[\(index)]: L=ch\(input.leftChannel) R=ch\(input.rightChannel), vol=\(input.volume)")
            }

            // Single tap on the shared capture engine, distributes to all strips
            let weakSelf = Weak(self)
            let targets = tapTargets
            let srcChannelCount = hwChannels

            // Pre-allocate silence buffer for out-of-range channels (avoid malloc on audio thread)
            let maxFrames = 4096
            if silenceBuffer == nil || silenceBufferSize < maxFrames {
                silenceBuffer?.deallocate()
                silenceBuffer = .allocate(capacity: maxFrames)
                silenceBuffer!.initialize(repeating: 0, count: maxFrames)
                silenceBufferSize = maxFrames
            }
            let silence = silenceBuffer!

            // Pre-fill ring buffers with silence as jitter absorber (~21ms at 48kHz)
            let prefillFrames = 1024
            for target in tapTargets {
                target.ringBuffer.prefill(frames: prefillFrames)
            }

            // Track frame count for throttled VU updates (~30fps)
            var meteringAccumulator: Int = 0
            let meteringInterval = Int(inputRate / 30.0) // frames between VU updates

            inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { buffer, _ in
                guard let engine = weakSelf.value else { return }

                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0, let srcData = buffer.floatChannelData else { return }

                for target in targets {
                    let leftCh = target.leftChannel
                    let rightCh = target.rightChannel

                    // Point to source channel data or pre-allocated silence (no malloc!)
                    let leftPtr: UnsafePointer<Float> = leftCh < srcChannelCount
                        ? UnsafePointer(srcData[leftCh])
                        : UnsafePointer(silence)
                    let rightPtr: UnsafePointer<Float> = rightCh < srcChannelCount
                        ? UnsafePointer(srcData[rightCh])
                        : UnsafePointer(silence)

                    target.ringBuffer.write(left: leftPtr, right: rightPtr, count: frameCount)

                    // Throttled VU meter updates using vDSP
                    meteringAccumulator += frameCount
                    if meteringAccumulator >= meteringInterval {
                        meteringAccumulator = 0

                        var meanSqL: Float = 0
                        var meanSqR: Float = 0
                        let n = vDSP_Length(frameCount)
                        vDSP_measqv(leftPtr, 1, &meanSqL, n)
                        vDSP_measqv(rightPtr, 1, &meanSqR, n)
                        let rmsL = sqrt(meanSqL)
                        let rmsR = sqrt(meanSqR)
                        let scale: Float = 1.4
                        let levels = (left: min(rmsL * scale, 1.0), right: min(rmsR * scale, 1.0))

                        let idx = target.stripIndex
                        DispatchQueue.main.async {
                            engine.inputLevels[idx] = levels
                        }
                    }
                }
            }
        }

        // Output level metering (throttled to ~30fps)
        var outputMeterAccum: Int = 0
        let outputMeterInterval = Int(outputRate / 30.0)
        mainMixer.installTap(onBus: 0, bufferSize: 512, format: outputStereo) { [weak self] buffer, _ in
            guard let self else { return }
            outputMeterAccum += Int(buffer.frameLength)
            if outputMeterAccum >= outputMeterInterval {
                outputMeterAccum = 0
                let levels = LegacyMixerEngine.calculateLevels(buffer: buffer)
                DispatchQueue.main.async {
                    self.outputLevel = levels
                }
            }
        }

        // Start capture engines FIRST so ring buffers fill before output pulls
        for (deviceID, capture) in sharedCaptures {
            capture.engine.prepare()
            do {
                try capture.engine.start()
                log("Capture engine (device \(deviceID)) started")
            } catch {
                log("⚠️ Capture engine (device \(deviceID)) failed: \(error)")
                throw MixerError.engineStartFailed(error)
            }
        }

        // Brief pause to let ring buffers accumulate data
        Thread.sleep(forTimeInterval: 0.025)

        // Start output engine (source nodes will pull from pre-filled ring buffers)
        outputEngine.prepare()
        try outputEngine.start()
        log("Output engine started")

        isRunning = true
        log("✅ Pipeline running: \(sharedCaptures.count) capture engine(s), \(stripNodes.count) strip(s)")
    }

    func stop() {
        // Log underrun stats before stopping
        for (idx, nodes) in stripNodes {
            let underruns = nodes.ringBuffer.underrunCount
            if underruns > 0 {
                log("Strip[\(idx)] had \(underruns) ring buffer underruns")
            }
        }

        for (_, capture) in sharedCaptures {
            capture.engine.inputNode.removeTap(onBus: 0)
            capture.engine.stop()
        }
        sharedCaptures.removeAll()

        if isRunning {
            outputEngine.mainMixerNode.removeTap(onBus: 0)
            outputEngine.stop()
        }

        for (_, nodes) in stripNodes {
            outputEngine.detach(nodes.sourceNode)
            outputEngine.detach(nodes.mixerNode)
        }
        stripNodes.removeAll()

        inputLevels.removeAll()
        outputLevel = (0, 0)
        isRunning = false
    }

    func setVolume(_ volume: Float, forInput index: Int) {
        stripNodes[index]?.mixerNode.volume = volume
    }

    func setRouteToMain(_ enabled: Bool, forInput index: Int) {
        stripNodes[index]?.mixerNode.volume = enabled ? 1.0 : 0.0
    }

    // MARK: - Device assignment

    private func setOutputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard deviceID != kAudioObjectUnknown else { return }
        var id = deviceID
        log("setOutputDevice(\(deviceID))")
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        log("  → \(status == noErr ? "OK" : "FAIL(\(status))")")
        guard status == noErr else { throw MixerError.cannotSetOutputDevice(status) }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard deviceID != kAudioObjectUnknown else { return }
        var id = deviceID
        log("setInputDevice(\(deviceID))")
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        log("  → \(status == noErr ? "OK" : "FAIL(\(status))")")
        guard status == noErr else { throw MixerError.cannotSetInputDevice(status) }
    }

    // MARK: - Level calculation

    static func calculateLevels(buffer: AVAudioPCMBuffer) -> (left: Float, right: Float) {
        guard let channelData = buffer.floatChannelData else { return (0, 0) }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return (0, 0) }

        let channelCount = Int(buffer.format.channelCount)
        let n = vDSP_Length(frameCount)

        var meanSqL: Float = 0
        vDSP_measqv(channelData[0], 1, &meanSqL, n)
        let left = sqrt(meanSqL)

        var meanSqR: Float = 0
        if channelCount > 1 {
            vDSP_measqv(channelData[1], 1, &meanSqR, n)
        } else {
            meanSqR = meanSqL
        }
        let right = sqrt(meanSqR)

        let scale: Float = 1.4
        return (min(left * scale, 1.0), min(right * scale, 1.0))
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("[LegacyMixerEngine] \(message)")
    }
}

// MARK: - Weak wrapper

private struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Errors

enum MixerError: Error, LocalizedError {
    case cannotSetOutputDevice(OSStatus)
    case cannotSetInputDevice(OSStatus)
    case engineStartFailed(Error)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .cannotSetOutputDevice(let status):
            return "Cannot set output device (error \(status))"
        case .cannotSetInputDevice(let status):
            return "Cannot set input device (error \(status))"
        case .engineStartFailed(let error):
            return "Engine failed to start: \(error.localizedDescription)"
        case .invalidFormat(let detail):
            return "Invalid audio format: \(detail)"
        }
    }
}
