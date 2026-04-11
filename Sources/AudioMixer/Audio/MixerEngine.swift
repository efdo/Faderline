import AVFoundation
import CoreAudio

/// Manages the AVAudioEngine graph: inputs → per-input mixer → main mixer → output.
@Observable
final class MixerEngine {
    private let engine = AVAudioEngine()

    /// Per-input player nodes that read from input devices.
    private var inputNodes: [Int: AVAudioInputNode] = [:]
    private var inputMixerNodes: [Int: AVAudioMixerNode] = [:]
    private var inputTapBlocks: [Int: Bool] = [:]

    /// Level meter values (0.0 – 1.0) updated from audio taps.
    private(set) var inputLevels: [Int: (left: Float, right: Float)] = [:]
    private(set) var outputLevel: (left: Float, right: Float) = (0, 0)

    private(set) var isRunning = false
    private var currentInputDeviceIDs: [Int: AudioDeviceID] = [:]
    private var currentOutputDeviceID: AudioDeviceID?

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

    // MARK: - Engine lifecycle

    /// Build and start the audio engine with the given configuration.
    func start(inputs: [InputConfig], output: OutputConfig) throws {
        stop()

        // Set the output device on the engine's output node.
        try setOutputDevice(output.deviceID)

        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: 2
        )!

        // For each input, create an aggregate approach:
        // We'll use separate AVAudioEngine instances per input device to capture,
        // then pipe into the main engine via mixer nodes.
        //
        // Simpler approach for v1: Use the system's aggregate device or
        // tap each device using CoreAudio directly and push buffers.
        //
        // For now, we use a practical approach: one engine, schedule buffers
        // from CoreAudio input taps into player nodes.

        for (index, input) in inputs.enumerated() {
            guard input.routeToMain, input.deviceID != kAudioObjectUnknown else { continue }

            let mixerNode = AVAudioMixerNode()
            engine.attach(mixerNode)
            engine.connect(mixerNode, to: mainMixer, format: stereoFormat)
            mixerNode.volume = input.volume
            inputMixerNodes[index] = mixerNode

            // Install input tap via CoreAudio for this specific device
            startInputCapture(
                index: index,
                deviceID: input.deviceID,
                leftChannel: input.leftChannel,
                rightChannel: input.rightChannel,
                mixerNode: mixerNode,
                format: stereoFormat
            )
        }

        // Install tap on main mixer for output level metering
        installOutputLevelTap(on: mainMixer, format: stereoFormat)

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if isRunning {
            engine.stop()
        }
        stopAllInputCaptures()

        for (_, node) in inputMixerNodes {
            engine.detach(node)
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

    /// Mute/unmute an input by disconnecting/reconnecting its mixer node.
    func setRouteToMain(_ enabled: Bool, forInput index: Int) {
        guard let node = inputMixerNodes[index] else { return }
        node.volume = enabled ? 1.0 : 0.0
    }

    // MARK: - Output device selection

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard deviceID != kAudioObjectUnknown else { return }

        let outputNode = engine.outputNode
        var deviceIDVar = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitSetProperty(
            outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            size
        )
        guard status == noErr else {
            throw MixerError.cannotSetOutputDevice(status)
        }
        currentOutputDeviceID = deviceID
    }

    // MARK: - Input capture using CoreAudio

    /// Per-input capture state
    private var inputCaptureUnits: [Int: AudioComponentInstance] = [:]

    private func startInputCapture(
        index: Int,
        deviceID: AudioDeviceID,
        leftChannel: Int,
        rightChannel: Int,
        mixerNode: AVAudioMixerNode,
        format: AVAudioFormat
    ) {
        // Create an AUHAL (Audio Unit HAL) for this input device
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else { return }

        var audioUnit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &audioUnit) == noErr,
              let unit = audioUnit else { return }

        // Enable input on the AUHAL
        var enableIO: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enableIO,
                             UInt32(MemoryLayout<UInt32>.size))

        // Disable output on the AUHAL (we only want to capture)
        var disableIO: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &disableIO,
                             UInt32(MemoryLayout<UInt32>.size))

        // Set the input device
        var deviceIDVar = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &deviceIDVar,
                             UInt32(MemoryLayout<AudioDeviceID>.size))

        // Configure the stream format for output (what we read from the unit)
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &streamFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // Set up the render callback that will push audio into the mixer node
        let context = InputCaptureContext(
            engine: self,
            index: index,
            mixerNode: mixerNode,
            format: format,
            leftChannel: leftChannel,
            rightChannel: rightChannel
        )
        let contextPtr = UnsafeMutablePointer<InputCaptureContext>.allocate(capacity: 1)
        contextPtr.initialize(to: context)

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputRenderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(contextPtr)
        )
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callbackStruct,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioUnitInitialize(unit)
        AudioOutputUnitStart(unit)
        inputCaptureUnits[index] = unit
    }

    private func stopAllInputCaptures() {
        for (_, unit) in inputCaptureUnits {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputCaptureUnits.removeAll()
    }

    // MARK: - Output level metering

    private func installOutputLevelTap(on mixer: AVAudioMixerNode, format: AVAudioFormat) {
        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: 2
        )!

        mixer.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let levels = Self.calculateLevels(buffer: buffer)
            DispatchQueue.main.async {
                self.outputLevel = levels
            }
        }
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

        // Convert to a 0–1 range with some scaling for visual display
        let scale: Float = 1.4
        return (min(left * scale, 1.0), min(right * scale, 1.0))
    }
}

// MARK: - Input render callback

private struct InputCaptureContext {
    weak var engine: MixerEngine?
    let index: Int
    let mixerNode: AVAudioMixerNode
    let format: AVAudioFormat
    let leftChannel: Int
    let rightChannel: Int
}

private func inputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // This callback is invoked by the AUHAL when input data is available.
    // In a full implementation, we'd render from the AUHAL into a buffer,
    // remap channels, and schedule into the AVAudioEngine player node.
    // For v1, this is a placeholder that will be connected during integration.
    return noErr
}

// MARK: - Errors

enum MixerError: Error, LocalizedError {
    case cannotSetOutputDevice(OSStatus)
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cannotSetOutputDevice(let status):
            return "Cannot set output device (error \(status))"
        case .engineStartFailed(let error):
            return "Engine failed to start: \(error.localizedDescription)"
        }
    }
}
