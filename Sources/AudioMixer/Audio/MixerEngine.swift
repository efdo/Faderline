import AVFoundation
import Accelerate
import CoreAudio

// MARK: - Lock-free SPSC Stereo Ring Buffer

/// SPSC stereo ring buffer optimized for real-time audio.
/// Lock only protects head pointer reads/writes (~2ns). All memcpy happens outside the lock.
private final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storageL: UnsafeMutablePointer<Float>
    private let storageR: UnsafeMutablePointer<Float>
    private let headLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _writeHead: Int = 0
    private var _readHead: Int = 0
    private(set) var underrunCount: Int = 0

    init(capacity: Int = 32768) {
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

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        // 1. Snapshot writeHead under lock (~2ns)
        os_unfair_lock_lock(headLock)
        let wh = _writeHead
        os_unfair_lock_unlock(headLock)

        // 2. memcpy OUTSIDE lock — safe: producer writes ahead of writeHead,
        //    consumer reads behind readHead (non-overlapping regions in power-of-2 buffer)
        let startIdx = wh & mask
        if startIdx + count <= capacity {
            memcpy(storageL + startIdx, left, count * MemoryLayout<Float>.size)
            memcpy(storageR + startIdx, right, count * MemoryLayout<Float>.size)
        } else {
            let firstPart = capacity - startIdx
            let secondPart = count - firstPart
            memcpy(storageL + startIdx, left, firstPart * MemoryLayout<Float>.size)
            memcpy(storageR + startIdx, right, firstPart * MemoryLayout<Float>.size)
            memcpy(storageL, left + firstPart, secondPart * MemoryLayout<Float>.size)
            memcpy(storageR, right + firstPart, secondPart * MemoryLayout<Float>.size)
        }

        // 3. Publish new writeHead under lock
        os_unfair_lock_lock(headLock)
        _writeHead = wh + count
        if _writeHead - _readHead > capacity {
            _readHead = _writeHead - capacity
        }
        os_unfair_lock_unlock(headLock)
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        // 1. Snapshot both heads under lock (~2ns)
        os_unfair_lock_lock(headLock)
        let wh = _writeHead
        let rh = _readHead
        os_unfair_lock_unlock(headLock)

        let available = wh - rh
        let toRead = min(count, available)

        // 2. memcpy OUTSIDE lock
        if toRead > 0 {
            let startIdx = rh & mask
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
        }

        // 3. Update readHead under lock
        os_unfair_lock_lock(headLock)
        _readHead = rh + toRead
        if toRead < count { underrunCount += 1 }
        os_unfair_lock_unlock(headLock)

        // 4. Fill remaining with silence (underrun)
        let silenceCount = count - toRead
        if silenceCount > 0 {
            memset(left + toRead, 0, silenceCount * MemoryLayout<Float>.size)
            memset(right + toRead, 0, silenceCount * MemoryLayout<Float>.size)
        }
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
final class MixerEngine {
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
        let ringBuffer: StereoRingBuffer
        /// Volume pointer for lock-free access from render thread.
        let volumePtr: UnsafeMutablePointer<Float>
    }

    private struct TapTarget {
        let stripIndex: Int
        let leftChannel: Int
        let rightChannel: Int
        let ringBuffer: StereoRingBuffer
        let converter: AVAudioConverter?
        let srcInputFormat: AVAudioFormat?
        let srcOutputFormat: AVAudioFormat?
    }

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

        // Pre-allocate silence buffer
        let maxFrames = 4096
        if silenceBuffer == nil || silenceBufferSize < maxFrames {
            silenceBuffer?.deallocate()
            silenceBuffer = .allocate(capacity: maxFrames)
            silenceBuffer!.initialize(repeating: 0, count: maxFrames)
            silenceBufferSize = maxFrames
        }
        let silence = silenceBuffer!

        // For each unique device, create ONE shared capture engine
        for (deviceID, strips) in deviceStrips {
            let captureEngine = AVAudioEngine()
            try setInputDevice(deviceID, on: captureEngine)

            let hwChannels = MixerEngine.deviceInputChannelCount(deviceID)
            let inputRate = MixerEngine.deviceSampleRate(deviceID)

            log("Device \(deviceID): HAL hwChannels=\(hwChannels), HAL rate=\(inputRate) Hz, serving \(strips.count) strip(s)")

            guard inputRate > 0 else {
                throw MixerError.invalidFormat("Input device \(deviceID) sample rate is 0")
            }
            guard hwChannels > 0 else {
                throw MixerError.invalidFormat("Input device \(deviceID) has 0 channels")
            }

            let hwFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: AVAudioChannelCount(hwChannels))!

            // Build valid graph on capture engine (silenced output)
            let inputNode = captureEngine.inputNode
            let captureMixer = captureEngine.mainMixerNode
            captureEngine.connect(inputNode, to: captureMixer, format: hwFormat)
            captureMixer.outputVolume = 0

            sharedCaptures[deviceID] = SharedCapture(engine: captureEngine, hwChannelCount: hwChannels, sampleRate: inputRate)

            // Determine if SRC is needed
            let needsSRC = abs(inputRate - outputRate) > 1.0
            let inputStereo = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 2)!

            var tapTargets: [TapTarget] = []

            for (index, input) in strips {
                let ringBuffer = StereoRingBuffer(capacity: 32768)

                // Volume pointer for lock-free access from render thread
                let volumePtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                volumePtr.initialize(to: input.volume)

                // Source node outputs at OUTPUT rate, connects directly to mainMixer
                let sourceNode = AVAudioSourceNode(format: outputStereo) { _, _, frameCount, audioBufferList in
                    let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    guard ablPointer.count >= 2 else { return noErr }

                    let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
                    let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)
                    let frames = Int(frameCount)

                    ringBuffer.read(left: leftPtr, right: rightPtr, count: frames)

                    // Apply volume via vDSP (in-place, zero allocation)
                    var vol = volumePtr.pointee
                    if vol != 1.0 {
                        vDSP_vsmul(leftPtr, 1, &vol, leftPtr, 1, vDSP_Length(frames))
                        vDSP_vsmul(rightPtr, 1, &vol, rightPtr, 1, vDSP_Length(frames))
                    }

                    ablPointer[0].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
                    ablPointer[1].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)

                    return noErr
                }

                // Connect directly to mainMixer — NO intermediate mixer node
                outputEngine.attach(sourceNode)
                outputEngine.connect(sourceNode, to: mainMixer, format: outputStereo)

                stripNodes[index] = StripNodes(sourceNode: sourceNode, ringBuffer: ringBuffer, volumePtr: volumePtr)

                // SRC converter if input rate differs from output rate
                let converter: AVAudioConverter?
                if needsSRC {
                    converter = AVAudioConverter(from: inputStereo, to: outputStereo)
                    converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                } else {
                    converter = nil
                }

                tapTargets.append(TapTarget(
                    stripIndex: index,
                    leftChannel: input.leftChannel,
                    rightChannel: input.rightChannel,
                    ringBuffer: ringBuffer,
                    converter: converter,
                    srcInputFormat: needsSRC ? inputStereo : nil,
                    srcOutputFormat: needsSRC ? outputStereo : nil
                ))

                log("  Strip[\(index)]: L=ch\(input.leftChannel) R=ch\(input.rightChannel), vol=\(input.volume), SRC=\(needsSRC)")
            }

            // Single tap on the shared capture engine distributes to all strips
            let weakSelf = Weak(self)
            let targets = tapTargets
            let srcChannelCount = hwChannels
            var meteringAccumulator: Int = 0
            let meteringInterval = Int(inputRate / 30.0)

            inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { buffer, _ in
                guard let engine = weakSelf.value else { return }

                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0, let srcData = buffer.floatChannelData else { return }

                for target in targets {
                    let leftCh = target.leftChannel
                    let rightCh = target.rightChannel

                    let leftPtr: UnsafePointer<Float> = leftCh < srcChannelCount
                        ? UnsafePointer(srcData[leftCh])
                        : UnsafePointer(silence)
                    let rightPtr: UnsafePointer<Float> = rightCh < srcChannelCount
                        ? UnsafePointer(srcData[rightCh])
                        : UnsafePointer(silence)

                    if let converter = target.converter,
                       let srcFmt = target.srcInputFormat,
                       let dstFmt = target.srcOutputFormat {
                        // SRC path: remap channels → convert rate → write to ring buffer
                        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(frameCount)) else { continue }
                        inputBuf.frameLength = AVAudioFrameCount(frameCount)
                        if let dst = inputBuf.floatChannelData {
                            memcpy(dst[0], leftPtr, frameCount * MemoryLayout<Float>.size)
                            memcpy(dst[1], rightPtr, frameCount * MemoryLayout<Float>.size)
                        }
                        let ratio = dstFmt.sampleRate / srcFmt.sampleRate
                        let outFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 4
                        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outFrames) else { continue }
                        var gotInput = false
                        let status = converter.convert(to: outputBuf, error: nil) { _, outStatus in
                            if gotInput {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                            gotInput = true
                            outStatus.pointee = .haveData
                            return inputBuf
                        }
                        guard status != .error, let outData = outputBuf.floatChannelData else { continue }
                        let outCount = Int(outputBuf.frameLength)
                        target.ringBuffer.write(left: outData[0], right: outData[1], count: outCount)
                    } else {
                        // No SRC needed: write directly to ring buffer
                        target.ringBuffer.write(left: leftPtr, right: rightPtr, count: frameCount)
                    }

                    // Throttled VU meter updates
                    meteringAccumulator += frameCount
                    if meteringAccumulator >= meteringInterval {
                        meteringAccumulator = 0
                        var meanSqL: Float = 0
                        var meanSqR: Float = 0
                        let n = vDSP_Length(frameCount)
                        vDSP_measqv(leftPtr, 1, &meanSqL, n)
                        vDSP_measqv(rightPtr, 1, &meanSqR, n)
                        let scale: Float = 1.4
                        let levels = (left: min(sqrt(meanSqL) * scale, 1.0), right: min(sqrt(meanSqR) * scale, 1.0))
                        let idx = target.stripIndex
                        DispatchQueue.main.async { engine.inputLevels[idx] = levels }
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
                let levels = MixerEngine.calculateLevels(buffer: buffer)
                DispatchQueue.main.async { self.outputLevel = levels }
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

        // Wait for ring buffers to accumulate real audio (no silence pre-fill)
        let waitStart = DispatchTime.now()
        let minFrames = 2048
        while true {
            let allReady = stripNodes.values.allSatisfy { nodes in nodes.ringBuffer.availableFrames >= minFrames }
            if allReady { break }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - waitStart.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 0.5 { log("⚠️ Ring buffer fill timeout after 500ms"); break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        log("Ring buffers ready, starting output engine")

        // Start output engine — source nodes will immediately have real data to pull
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
            nodes.volumePtr.deallocate()
        }
        stripNodes.removeAll()

        inputLevels.removeAll()
        outputLevel = (0, 0)
        isRunning = false
    }

    func setVolume(_ volume: Float, forInput index: Int) {
        stripNodes[index]?.volumePtr.pointee = volume
    }

    func setRouteToMain(_ enabled: Bool, forInput index: Int) {
        stripNodes[index]?.volumePtr.pointee = enabled ? 1.0 : 0.0
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
        print("[MixerEngine] \(message)")
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
