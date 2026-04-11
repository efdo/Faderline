import AVFoundation
import CoreAudio
import os

// MARK: - Stereo Ring Buffer (SPSC, lock-based)

/// A simple stereo ring buffer for passing audio between a tap (producer)
/// and an AVAudioSourceNode render callback (consumer).
private final class StereoRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private var bufferL: [Float]
    private var bufferR: [Float]
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int = 8192) {
        let cap = 1 << Int(ceil(log2(Double(max(capacity, 64)))))
        self.capacity = cap
        self.mask = cap - 1
        self.bufferL = [Float](repeating: 0, count: cap)
        self.bufferR = [Float](repeating: 0, count: cap)
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            for i in 0..<count {
                let idx = (writeHead + i) & mask
                bufferL[idx] = left[i]
                bufferR[idx] = right[i]
            }
            writeHead += count
            if writeHead - readHead > capacity {
                readHead = writeHead - capacity
            }
        }
    }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        lock.withLock {
            let available = writeHead - readHead
            let toRead = min(count, available)
            let silenceCount = count - toRead

            for i in 0..<toRead {
                let idx = (readHead + i) & mask
                left[i] = bufferL[idx]
                right[i] = bufferR[idx]
            }
            readHead += toRead

            if silenceCount > 0 {
                memset(left.advanced(by: toRead), 0, silenceCount * MemoryLayout<Float>.size)
                memset(right.advanced(by: toRead), 0, silenceCount * MemoryLayout<Float>.size)
            }
        }
    }

    func reset() {
        lock.withLock {
            writeHead = 0
            readHead = 0
        }
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
        let mixerNode: AVAudioMixerNode
        let ringBuffer: StereoRingBuffer
    }

    private struct TapTarget {
        let stripIndex: Int
        let leftChannel: Int
        let rightChannel: Int
        let ringBuffer: StereoRingBuffer
    }

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
            let hwChannels = MixerEngine.deviceInputChannelCount(deviceID)
            let inputRate = MixerEngine.deviceSampleRate(deviceID)

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

            inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { buffer, _ in
                guard let engine = weakSelf.value else { return }

                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0, let srcData = buffer.floatChannelData else { return }

                for target in targets {
                    let leftCh = target.leftChannel
                    let rightCh = target.rightChannel

                    let leftPtr: UnsafePointer<Float>
                    let rightPtr: UnsafePointer<Float>

                    if leftCh < srcChannelCount {
                        leftPtr = UnsafePointer(srcData[leftCh])
                    } else {
                        let silence = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
                        memset(silence, 0, frameCount * MemoryLayout<Float>.size)
                        leftPtr = UnsafePointer(silence)
                    }

                    if rightCh < srcChannelCount {
                        rightPtr = UnsafePointer(srcData[rightCh])
                    } else {
                        let silence = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
                        memset(silence, 0, frameCount * MemoryLayout<Float>.size)
                        rightPtr = UnsafePointer(silence)
                    }

                    target.ringBuffer.write(left: leftPtr, right: rightPtr, count: frameCount)

                    // Update VU levels from the input data
                    var sumL: Float = 0, sumR: Float = 0
                    for i in 0..<frameCount {
                        sumL += leftPtr[i] * leftPtr[i]
                        sumR += rightPtr[i] * rightPtr[i]
                    }
                    let rmsL = sqrt(sumL / Float(frameCount))
                    let rmsR = sqrt(sumR / Float(frameCount))
                    let scale: Float = 1.4
                    let levels = (left: min(rmsL * scale, 1.0), right: min(rmsR * scale, 1.0))

                    let idx = target.stripIndex
                    DispatchQueue.main.async {
                        engine.inputLevels[idx] = levels
                    }
                }
            }
        }

        // Output level metering
        mainMixer.installTap(onBus: 0, bufferSize: 512, format: outputStereo) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = MixerEngine.calculateLevels(buffer: buffer)
            DispatchQueue.main.async {
                self.outputLevel = levels
            }
        }

        // Start output engine first (source nodes need it running to pull)
        outputEngine.prepare()
        try outputEngine.start()
        log("Output engine started")

        // Start capture engines last (taps will begin writing to ring buffers)
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

        isRunning = true
        log("✅ Pipeline running: \(sharedCaptures.count) capture engine(s), \(stripNodes.count) strip(s)")
    }

    func stop() {
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

        func rms(_ data: UnsafePointer<Float>, count: Int) -> Float {
            var sumOfSquares: Float = 0
            for i in 0..<count {
                sumOfSquares += data[i] * data[i]
            }
            return sqrt(sumOfSquares / Float(count))
        }

        let left = rms(channelData[0], count: frameCount)
        let right = channelCount > 1 ? rms(channelData[1], count: frameCount) : left

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
