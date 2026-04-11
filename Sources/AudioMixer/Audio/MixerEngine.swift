import AVFoundation
import CoreAudio

/// Manages audio routing: shared capture engines → player nodes → main mixer → output.
///
/// Architecture:
/// - One `AVAudioEngine` per unique input device (shared when multiple strips use the same device).
/// - A tap on each capture engine grabs all hardware channels.
/// - Per-strip channel remapping extracts L/R and schedules into player nodes on the output engine.
@Observable
final class MixerEngine {
    private var outputEngine = AVAudioEngine()
    /// One capture engine per unique device ID.
    private var sharedCaptures: [AudioDeviceID: SharedCapture] = [:]
    /// Per-strip player + mixer on the output engine.
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
        let hwFormat: AVAudioFormat
    }

    private struct StripNodes {
        let playerNode: AVAudioPlayerNode
        let mixerNode: AVAudioMixerNode
    }

    /// Info passed into tap closures for each strip sharing a capture engine.
    private struct TapTarget {
        let stripIndex: Int
        let leftChannel: Int
        let rightChannel: Int
        let playerNode: AVAudioPlayerNode
        let converter: AVAudioConverter?
        let inputStereoFormat: AVAudioFormat
        let outputStereoFormat: AVAudioFormat
        let outputRate: Double
        let inputRate: Double
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
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
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

            let inputNode = captureEngine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            let inputRate = hwFormat.sampleRate
            log("Device \(deviceID): hwChannels=\(hwFormat.channelCount), rate=\(inputRate) Hz, serving \(strips.count) strip(s)")

            guard inputRate > 0 else {
                throw MixerError.invalidFormat("Input device \(deviceID) sample rate is 0")
            }

            // Build valid graph on capture engine (silenced output)
            let captureMixer = captureEngine.mainMixerNode
            captureEngine.connect(inputNode, to: captureMixer, format: hwFormat)
            captureMixer.outputVolume = 0

            sharedCaptures[deviceID] = SharedCapture(engine: captureEngine, hwFormat: hwFormat)

            // Create player+mixer nodes for each strip using this device
            var tapTargets: [TapTarget] = []

            for (index, input) in strips {
                let playerNode = AVAudioPlayerNode()
                let mixerNode = AVAudioMixerNode()
                outputEngine.attach(playerNode)
                outputEngine.attach(mixerNode)
                outputEngine.connect(playerNode, to: mixerNode, format: stereoFormat)
                outputEngine.connect(mixerNode, to: mainMixer, format: stereoFormat)
                mixerNode.volume = input.volume
                stripNodes[index] = StripNodes(playerNode: playerNode, mixerNode: mixerNode)

                let inputStereo = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 2)!
                let needsSRC = abs(inputRate - outputRate) > 1.0
                let converter: AVAudioConverter? = needsSRC
                    ? AVAudioConverter(from: inputStereo, to: stereoFormat)
                    : nil

                tapTargets.append(TapTarget(
                    stripIndex: index,
                    leftChannel: input.leftChannel,
                    rightChannel: input.rightChannel,
                    playerNode: playerNode,
                    converter: converter,
                    inputStereoFormat: inputStereo,
                    outputStereoFormat: stereoFormat,
                    outputRate: outputRate,
                    inputRate: inputRate
                ))

                log("  Strip[\(index)]: L=ch\(input.leftChannel) R=ch\(input.rightChannel), vol=\(input.volume)")
            }

            // Single tap on the shared capture engine, distributes to all strips
            let weakSelf = Weak(self)
            let targets = tapTargets

            inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { buffer, _ in
                guard let engine = weakSelf.value else { return }

                for target in targets {
                    // 1) Remap channels at input sample rate
                    let remapped = engine.remapChannels(
                        buffer: buffer,
                        leftChannel: target.leftChannel,
                        rightChannel: target.rightChannel,
                        outputFormat: target.inputStereoFormat
                    )

                    // 2) Sample rate convert if needed
                    let finalBuffer: AVAudioPCMBuffer
                    if let converter = target.converter {
                        let ratio = target.outputRate / target.inputRate
                        let outFrames = AVAudioFrameCount(Double(remapped.frameLength) * ratio) + 2
                        guard let converted = AVAudioPCMBuffer(
                            pcmFormat: target.outputStereoFormat,
                            frameCapacity: outFrames
                        ) else { continue }

                        var gotInput = false
                        let status = converter.convert(to: converted, error: nil) { _, outStatus in
                            if gotInput {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                            gotInput = true
                            outStatus.pointee = .haveData
                            return remapped
                        }
                        guard status != .error else { continue }
                        finalBuffer = converted
                    } else {
                        finalBuffer = remapped
                    }

                    // 3) Update levels
                    let levels = MixerEngine.calculateLevels(buffer: finalBuffer)
                    let idx = target.stripIndex
                    DispatchQueue.main.async {
                        engine.inputLevels[idx] = levels
                    }

                    // 4) Schedule for playback
                    target.playerNode.scheduleBuffer(finalBuffer)
                }
            }
        }

        // Output level metering
        mainMixer.installTap(onBus: 0, bufferSize: 512, format: stereoFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = MixerEngine.calculateLevels(buffer: buffer)
            DispatchQueue.main.async {
                self.outputLevel = levels
            }
        }

        // Start output engine + player nodes first
        outputEngine.prepare()
        try outputEngine.start()
        log("Output engine started")

        for (idx, nodes) in stripNodes {
            nodes.playerNode.play()
            log("Player[\(idx)] playing")
        }

        // Start capture engines last
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

        for (_, nodes) in stripNodes {
            nodes.playerNode.stop()
        }

        if isRunning {
            outputEngine.mainMixerNode.removeTap(onBus: 0)
            outputEngine.stop()
        }

        for (_, nodes) in stripNodes {
            outputEngine.detach(nodes.playerNode)
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

    // MARK: - Channel remapping

    private func remapChannels(
        buffer: AVAudioPCMBuffer,
        leftChannel: Int,
        rightChannel: Int,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let frameCount = buffer.frameLength
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return buffer
        }
        outBuffer.frameLength = frameCount

        guard let srcData = buffer.floatChannelData,
              let dstData = outBuffer.floatChannelData else {
            return buffer
        }

        let srcChannelCount = Int(buffer.format.channelCount)
        let frames = Int(frameCount)

        if leftChannel < srcChannelCount {
            memcpy(dstData[0], srcData[leftChannel], frames * MemoryLayout<Float>.size)
        } else {
            memset(dstData[0], 0, frames * MemoryLayout<Float>.size)
        }

        if rightChannel < srcChannelCount {
            memcpy(dstData[1], srcData[rightChannel], frames * MemoryLayout<Float>.size)
        } else {
            memset(dstData[1], 0, frames * MemoryLayout<Float>.size)
        }

        return outBuffer
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
