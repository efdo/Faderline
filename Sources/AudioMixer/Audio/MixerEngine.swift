import AVFoundation
import CoreAudio

/// Manages audio routing: per-input capture engines → player nodes → main mixer → output.
///
/// Architecture:
/// - Each input device gets its own `AVAudioEngine` for capture.
/// - A tap on each capture engine's `inputNode` grabs PCM buffers.
/// - Buffers are channel-remapped and scheduled into `AVAudioPlayerNode`s
///   on the main output engine.
/// - The main engine's graph: playerNode → mixerNode (volume) → mainMixer → outputNode.
@Observable
final class MixerEngine {
    /// The output engine that mixes all inputs and sends to the selected output device.
    private var outputEngine = AVAudioEngine()

    /// Per-input capture state.
    private var captures: [Int: InputCapture] = [:]

    /// Per-input mixer nodes on the output engine (for volume control).
    private var inputMixerNodes: [Int: AVAudioMixerNode] = [:]

    /// Level meter values (0.0 – 1.0) updated from audio taps.
    private(set) var inputLevels: [Int: (left: Float, right: Float)] = [:]
    private(set) var outputLevel: (left: Float, right: Float) = (0, 0)

    private(set) var isRunning = false

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

    /// Build and start the full audio graph with the given configuration.
    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()

        outputEngine = AVAudioEngine()

        // Set the output device on the output engine.
        try setOutputDevice(output.deviceID, on: outputEngine)

        let mainMixer = outputEngine.mainMixerNode
        let sampleRate = mainMixer.outputFormat(forBus: 0).sampleRate
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

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

            // We need to connect inputNode → mainMixer on the capture engine
            // so it has a valid graph. We won't use the capture engine's output.
            let captureMixer = captureEngine.mainMixerNode
            captureEngine.connect(inputNode, to: captureMixer, format: hwFormat)
            // Silence the capture engine's output so it doesn't play back through speakers
            captureMixer.outputVolume = 0

            let capture = InputCapture(
                captureEngine: captureEngine,
                playerNode: playerNode,
                leftChannel: input.leftChannel,
                rightChannel: input.rightChannel
            )
            captures[index] = capture

            // Install tap to grab audio and push into the output engine's player node
            let leftCh = input.leftChannel
            let rightCh = input.rightChannel
            let weakSelf = Weak(self)
            let captureIndex = index

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weakSelf] buffer, _ in
                guard let engine = weakSelf.value else { return }
                let remapped = engine.remapChannels(
                    buffer: buffer,
                    leftChannel: leftCh,
                    rightChannel: rightCh,
                    outputFormat: stereoFormat
                )
                // Update input levels
                let levels = MixerEngine.calculateLevels(buffer: remapped)
                DispatchQueue.main.async {
                    engine.inputLevels[captureIndex] = levels
                }
                // Schedule the remapped buffer for playback on the output engine
                playerNode.scheduleBuffer(remapped)
            }
        }

        // Install tap on main mixer for output level metering
        let outputTapFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        mainMixer.installTap(onBus: 0, bufferSize: 1024, format: outputTapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = MixerEngine.calculateLevels(buffer: buffer)
            DispatchQueue.main.async {
                self.outputLevel = levels
            }
        }

        // Start all engines: capture engines first, then the output engine
        for (_, capture) in captures {
            capture.captureEngine.prepare()
            try capture.captureEngine.start()
        }

        outputEngine.prepare()
        try outputEngine.start()

        // Start all player nodes
        for (_, capture) in captures {
            capture.playerNode.play()
        }

        isRunning = true
    }

    func stop() {
        // Stop capture engines and remove taps
        for (_, capture) in captures {
            capture.captureEngine.inputNode.removeTap(onBus: 0)
            capture.captureEngine.stop()
            capture.playerNode.stop()
        }
        captures.removeAll()

        // Remove output tap and stop
        if isRunning {
            outputEngine.mainMixerNode.removeTap(onBus: 0)
            outputEngine.stop()
        }

        // Detach all nodes from the output engine
        for (_, node) in inputMixerNodes {
            outputEngine.detach(node)
        }
        inputMixerNodes.removeAll()
        inputLevels.removeAll()
        outputLevel = (0, 0)
        isRunning = false
    }

    /// Update volume for a specific input strip.
    func setVolume(_ volume: Float, forInput index: Int) {
        inputMixerNodes[index]?.volume = volume
    }

    /// Mute/unmute an input strip.
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

    /// Takes a multi-channel input buffer and produces a stereo buffer
    /// with the specified channels mapped to L and R.
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

        // Map selected left channel → output L
        if leftChannel < srcChannelCount {
            memcpy(dstData[0], srcData[leftChannel], frames * MemoryLayout<Float>.size)
        } else {
            // If channel doesn't exist, fill with silence
            memset(dstData[0], 0, frames * MemoryLayout<Float>.size)
        }

        // Map selected right channel → output R
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

        // Scale for visual display (0–1 range)
        let scale: Float = 1.4
        return (min(left * scale, 1.0), min(right * scale, 1.0))
    }
}

// MARK: - Weak wrapper for use in closures (avoids capturing self strongly in C-bridged contexts)

private struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Errors

enum MixerError: Error, LocalizedError {
    case cannotSetOutputDevice(OSStatus)
    case cannotSetInputDevice(OSStatus)
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cannotSetOutputDevice(let status):
            return "Cannot set output device (error \(status))"
        case .cannotSetInputDevice(let status):
            return "Cannot set input device (error \(status))"
        case .engineStartFailed(let error):
            return "Engine failed to start: \(error.localizedDescription)"
        }
    }
}
