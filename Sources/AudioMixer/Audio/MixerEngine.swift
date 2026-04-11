import AVFoundation
import CoreAudio

/// Manages audio routing: per-input capture engines → player nodes → main mixer → output.
///
/// Architecture:
/// - Each input device gets its own `AVAudioEngine` for capture.
/// - A tap on each capture engine's `inputNode` grabs PCM buffers.
/// - Buffers are channel-remapped, sample-rate-converted, and scheduled into
///   `AVAudioPlayerNode`s on the main output engine.
@Observable
final class MixerEngine {
    private var outputEngine = AVAudioEngine()
    private var captures: [Int: InputCapture] = [:]
    private var inputMixerNodes: [Int: AVAudioMixerNode] = [:]

    private(set) var inputLevels: [Int: (left: Float, right: Float)] = [:]
    private(set) var outputLevel: (left: Float, right: Float) = (0, 0)
    private(set) var isRunning = false

    /// Last error message, displayed in the UI for diagnostics.
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

    // MARK: - Per-input capture

    private struct InputCapture {
        let captureEngine: AVAudioEngine
        let playerNode: AVAudioPlayerNode
        let leftChannel: Int
        let rightChannel: Int
    }

    // MARK: - Engine lifecycle

    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()
        lastError = nil

        guard output.deviceID != kAudioObjectUnknown else {
            log("No output device selected, skipping engine start")
            return
        }

        outputEngine = AVAudioEngine()

        // Set the output device and query its native format
        try setOutputDevice(output.deviceID, on: outputEngine)
        let outputHwFormat = outputEngine.outputNode.outputFormat(forBus: 0)
        let outputRate = outputHwFormat.sampleRate
        guard outputRate > 0 else {
            throw MixerError.invalidFormat("Output device sample rate is 0")
        }
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        log("Output engine: rate=\(outputRate) Hz, format=\(stereoFormat)")

        let mainMixer = outputEngine.mainMixerNode

        for (index, input) in inputs.enumerated() {
            guard input.routeToMain, input.deviceID != kAudioObjectUnknown else { continue }

            // --- Player + mixer on the output engine ---
            let playerNode = AVAudioPlayerNode()
            let mixerNode = AVAudioMixerNode()
            outputEngine.attach(playerNode)
            outputEngine.attach(mixerNode)
            outputEngine.connect(playerNode, to: mixerNode, format: stereoFormat)
            outputEngine.connect(mixerNode, to: mainMixer, format: stereoFormat)
            mixerNode.volume = input.volume
            inputMixerNodes[index] = mixerNode

            // --- Capture engine for this input device ---
            let captureEngine = AVAudioEngine()
            try setInputDevice(input.deviceID, on: captureEngine)

            let inputNode = captureEngine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            let inputRate = hwFormat.sampleRate
            log("Input[\(index)]: device=\(input.deviceID), hwChannels=\(hwFormat.channelCount), rate=\(inputRate) Hz, L=ch\(input.leftChannel) R=ch\(input.rightChannel)")

            guard inputRate > 0 else {
                throw MixerError.invalidFormat("Input device \(input.deviceID) sample rate is 0")
            }

            // Build a valid graph on the capture engine (output is silenced)
            let captureMixer = captureEngine.mainMixerNode
            captureEngine.connect(inputNode, to: captureMixer, format: hwFormat)
            captureMixer.outputVolume = 0

            let capture = InputCapture(
                captureEngine: captureEngine,
                playerNode: playerNode,
                leftChannel: input.leftChannel,
                rightChannel: input.rightChannel
            )
            captures[index] = capture

            // Prepare sample-rate converter if input ≠ output rate
            let inputStereo = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 2)!
            let needsSRC = abs(inputRate - outputRate) > 1.0
            let converter: AVAudioConverter? = needsSRC
                ? AVAudioConverter(from: inputStereo, to: stereoFormat)
                : nil
            if needsSRC {
                log("Input[\(index)]: will convert \(inputRate) → \(outputRate) Hz")
            }

            // Install tap
            let leftCh = input.leftChannel
            let rightCh = input.rightChannel
            let weakSelf = Weak(self)
            let captureIndex = index

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) {
                [weakSelf, converter, inputStereo] buffer, _ in
                guard let engine = weakSelf.value else { return }

                // 1) Remap channels to stereo at the INPUT sample rate
                let remapped = engine.remapChannels(
                    buffer: buffer,
                    leftChannel: leftCh,
                    rightChannel: rightCh,
                    outputFormat: inputStereo
                )

                // 2) Convert sample rate if needed
                let finalBuffer: AVAudioPCMBuffer
                if let converter {
                    let ratio = outputRate / inputRate
                    let outFrames = AVAudioFrameCount(Double(remapped.frameLength) * ratio) + 2
                    guard let converted = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: outFrames) else { return }

                    var gotInput = false
                    var convError: NSError?
                    let status = converter.convert(to: converted, error: &convError) { _, outStatus in
                        if gotInput {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        gotInput = true
                        outStatus.pointee = .haveData
                        return remapped
                    }
                    guard status != .error else { return }
                    finalBuffer = converted
                } else {
                    finalBuffer = remapped
                }

                // 3) Update input levels
                let levels = MixerEngine.calculateLevels(buffer: finalBuffer)
                DispatchQueue.main.async {
                    engine.inputLevels[captureIndex] = levels
                }

                // 4) Schedule for playback
                playerNode.scheduleBuffer(finalBuffer)
            }
        }

        // Output level metering tap
        mainMixer.installTap(onBus: 0, bufferSize: 1024, format: stereoFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = MixerEngine.calculateLevels(buffer: buffer)
            DispatchQueue.main.async {
                self.outputLevel = levels
            }
        }

        // Start output engine FIRST so player nodes are ready to accept buffers
        outputEngine.prepare()
        try outputEngine.start()
        log("Output engine started")

        // Start player nodes BEFORE capture engines to avoid dropping early buffers
        for (_, capture) in captures {
            capture.playerNode.play()
        }
        log("Player nodes playing")

        // Now start capture engines — taps will begin firing
        for (idx, capture) in captures {
            capture.captureEngine.prepare()
            do {
                try capture.captureEngine.start()
                log("Capture engine[\(idx)] started")
            } catch {
                log("⚠️ Capture engine[\(idx)] failed: \(error)")
                throw MixerError.engineStartFailed(error)
            }
        }

        isRunning = true
        log("✅ Audio pipeline running with \(captures.count) input(s)")
    }

    func stop() {
        for (_, capture) in captures {
            capture.captureEngine.inputNode.removeTap(onBus: 0)
            capture.captureEngine.stop()
            capture.playerNode.stop()
        }
        captures.removeAll()

        if isRunning {
            outputEngine.mainMixerNode.removeTap(onBus: 0)
            outputEngine.stop()
        }

        for (_, node) in inputMixerNodes {
            outputEngine.detach(node)
        }
        inputMixerNodes.removeAll()
        inputLevels.removeAll()
        outputLevel = (0, 0)
        isRunning = false
    }

    func setVolume(_ volume: Float, forInput index: Int) {
        inputMixerNodes[index]?.volume = volume
    }

    func setRouteToMain(_ enabled: Bool, forInput index: Int) {
        inputMixerNodes[index]?.volume = enabled ? 1.0 : 0.0
    }

    // MARK: - Device assignment

    private func setOutputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard deviceID != kAudioObjectUnknown else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MixerError.cannotSetOutputDevice(status) }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard deviceID != kAudioObjectUnknown else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
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
