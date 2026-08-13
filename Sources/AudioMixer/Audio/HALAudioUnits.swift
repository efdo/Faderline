import Foundation
import AudioToolbox
import CoreAudio
import Synchronization
import OSLog

private let halLogger = Logger(subsystem: "com.audiomixer", category: "HALAudioUnits")

/// Errors from the AUHAL layer.
enum HALUnitError: Error, LocalizedError {
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let op, let status):
            return "\(op) failed (OSStatus \(status))"
        }
    }
}

@inline(__always)
private func check(_ status: OSStatus, _ op: String) throws {
    guard status == noErr else { throw HALUnitError.osStatus(op, status) }
}

/// Shared CoreAudio HAL device queries.
enum HALDeviceInfo {
    /// Total channel count for a device in the given scope.
    static func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Nominal sample rate of a device.
    static func nominalSampleRate(deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }
}

/// Builds a Float32, deinterleaved (planar), native-endian ASBD.
private func planarFloatASBD(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

// MARK: - HALInputUnit

/// AUHAL unit configured for input-only capture from one device.
///
/// The input callback runs on the device's I/O thread: it renders the fresh
/// quantum into a pre-allocated planar AudioBufferList and pushes all hardware
/// channels into the device's `ChannelRingBuffer`.
final class HALInputUnit {
    let deviceID: AudioDeviceID
    let channelCount: Int
    let sampleRate: Double
    let ring: ChannelRingBuffer

    private var audioUnit: AudioUnit?
    private var context: InputContext?

    var inputCallbackCount: Int { context?.callbackCount.load(ordering: .relaxed) ?? 0 }
    #if DEBUG
    var inputCallbackTicks: Int { context?.callbackTicks.load(ordering: .relaxed) ?? 0 }
    var maxInputCallbackTicks: Int { context?.maxCallbackTicks.load(ordering: .relaxed) ?? 0 }
    #endif

    /// Real-time context handed to the C callback via inRefCon.
    /// Owns the render ABL and pointer table — allocated once, never resized.
    final class InputContext {
        var audioUnit: AudioUnit!
        let ring: ChannelRingBuffer
        let channelCount: Int
        let maxFrames: Int
        let bufferList: UnsafeMutableAudioBufferListPointer
        let channelPointers: UnsafeMutablePointer<UnsafePointer<Float>>
        let callbackCount = Atomic<Int>(0)
        #if DEBUG
        let callbackTicks = Atomic<Int>(0)
        let maxCallbackTicks = Atomic<Int>(0)
        #endif

        init(ring: ChannelRingBuffer, channelCount: Int, maxFrames: Int) {
            self.ring = ring
            self.channelCount = channelCount
            self.maxFrames = maxFrames
            self.bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
            self.channelPointers = .allocate(capacity: channelCount)
            for c in 0..<channelCount {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
                data.initialize(repeating: 0, count: maxFrames)
                bufferList[c] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(data)
                )
                channelPointers[c] = UnsafePointer(data)
            }
        }

        deinit {
            for c in 0..<channelCount {
                bufferList[c].mData?.assumingMemoryBound(to: Float.self).deallocate()
            }
            free(bufferList.unsafeMutablePointer)
            channelPointers.deallocate()
        }
    }

    init(deviceID: AudioDeviceID, ringCapacity: Int = 16384, maxFrames: Int = 4096) throws {
        self.deviceID = deviceID

        let channels = HALDeviceInfo.channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        let rate = HALDeviceInfo.nominalSampleRate(deviceID: deviceID)
        halLogger.info("HALInputUnit init: device=\(deviceID, privacy: .public) channels=\(channels, privacy: .public) rate=\(rate, privacy: .public)")
        guard channels > 0 else { throw HALUnitError.osStatus("Device \(deviceID) has no input channels", -1) }
        guard rate > 0 else { throw HALUnitError.osStatus("Device \(deviceID) sample rate query", -1) }
        self.channelCount = channels
        self.sampleRate = rate
        self.ring = ChannelRingBuffer(channelCount: channels, capacity: ringCapacity)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw HALUnitError.osStatus("AudioComponentFindNext(HALOutput)", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
        guard let au = unit else { throw HALUnitError.osStatus("AudioComponentInstanceNew", -1) }
        self.audioUnit = au
        halLogger.info("HALInputUnit: AU instance created, enabling IO")

        // 1. Enable input (element 1), disable output (element 0).
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, 4), "EnableIO input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable, 4), "DisableIO output")
        halLogger.info("HALInputUnit: IO enabled, binding device \(deviceID, privacy: .public)")

        // 2. Bind device.
        var dev = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Set current device")
        halLogger.info("HALInputUnit: device bound, setting stream format \(channels, privacy: .public)ch @ \(rate, privacy: .public)Hz")

        // 3. Client format on output scope of element 1 (what WE receive):
        //    planar Float32 at the device's native rate & channel count.
        //    AUHAL cannot rate-convert on input, so rate must match device.
        var fmt = planarFloatASBD(sampleRate: rate, channels: channels)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "Set input client format")
        halLogger.info("HALInputUnit: stream format set, setting max frames")

        // 4. Max frames per slice.
        var maxSlice = UInt32(maxFrames)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0, &maxSlice, 4), "Set max frames")
        halLogger.info("HALInputUnit: max frames set, setting input callback")

        // 5. Input callback.
        let ctx = InputContext(ring: ring, channelCount: channels, maxFrames: maxFrames)
        ctx.audioUnit = au
        self.context = ctx
        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque()
        )
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Set input callback")
        halLogger.info("HALInputUnit: callback set, calling AudioUnitInitialize")

        try check(AudioUnitInitialize(au), "AudioUnitInitialize(input)")
        halLogger.info("HALInputUnit: ✅ initialized successfully")
    }

    func start() throws {
        guard let au = audioUnit else { return }
        try check(AudioOutputUnitStart(au), "AudioOutputUnitStart(input)")
    }

    func stop() {
        guard let au = audioUnit else { return }
        AudioOutputUnitStop(au)
    }

    deinit {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
    }
}

/// C input callback: render the new quantum and push it into the ring buffer.
private func halInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<HALInputUnit.InputContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let frames = Int(inNumberFrames)
    guard frames <= ctx.maxFrames else { return noErr }
    #if DEBUG
    let startTicks = mach_absolute_time()
    #endif

    // Reset byte sizes (AudioUnitRender may shrink them on prior calls).
    for c in 0..<ctx.channelCount {
        ctx.bufferList[c].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
    }

    let status = AudioUnitRender(ctx.audioUnit, ioActionFlags, inTimeStamp,
                                 inBusNumber, inNumberFrames,
                                 ctx.bufferList.unsafeMutablePointer)
    guard status == noErr else { return status }

    // Refresh channel pointer table from post-render mData: AUHAL may have
    // swapped mData to point to its own internal buffers for efficiency.
    for c in 0..<ctx.channelCount {
        if let data = ctx.bufferList[c].mData {
            ctx.channelPointers[c] = UnsafePointer(data.assumingMemoryBound(to: Float.self))
        }
    }

    ctx.ring.write(channelPointers: UnsafePointer(ctx.channelPointers), count: frames)
    ctx.callbackCount.wrappingAdd(1, ordering: .relaxed)
    #if DEBUG
    let elapsedTicks = Int(mach_absolute_time() - startTicks)
    ctx.callbackTicks.wrappingAdd(elapsedTicks, ordering: .relaxed)
    if elapsedTicks > ctx.maxCallbackTicks.load(ordering: .relaxed) {
        ctx.maxCallbackTicks.store(elapsedTicks, ordering: .relaxed)
    }
    #endif
    return noErr
}

// MARK: - HALOutputUnit

/// AUHAL unit configured for output to one device. The render callback invokes
/// a mix handler that fills planar Float32 stereo buffers.
final class HALOutputUnit {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    let channelCount: Int = 2

    private var audioUnit: AudioUnit?
    private var context: RenderContext?

    /// The mix handler fills `dest` (planar, `channelCount` pointers) with
    /// `frameCount` frames. Runs on the real-time render thread: must not
    /// allocate, lock, or block.
    typealias MixHandler = (_ dest: UnsafePointer<UnsafeMutablePointer<Float>>, _ frameCount: Int) -> Void

    final class RenderContext {
        let channelCount: Int
        let handler: MixHandler
        let dest: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let callbackCount = Atomic<Int>(0)
        let lastFrameCount = Atomic<Int>(0)
        let maxFrameCount = Atomic<Int>(0)
        #if DEBUG
        let handlerTicks = Atomic<Int>(0)
        let maxHandlerTicks = Atomic<Int>(0)
        #endif

        init(channelCount: Int, handler: @escaping MixHandler) {
            self.channelCount = channelCount
            self.handler = handler
            self.dest = .allocate(capacity: channelCount)
        }

        deinit { dest.deallocate() }
    }

    init(deviceID: AudioDeviceID, maxFrames: Int = 4096, mixHandler: @escaping MixHandler) throws {
        self.deviceID = deviceID

        let rate = HALDeviceInfo.nominalSampleRate(deviceID: deviceID)
        guard rate > 0 else { throw HALUnitError.osStatus("Output device \(deviceID) sample rate query", -1) }
        self.sampleRate = rate

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw HALUnitError.osStatus("AudioComponentFindNext(HALOutput)", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "AudioComponentInstanceNew")
        guard let au = unit else { throw HALUnitError.osStatus("AudioComponentInstanceNew", -1) }
        self.audioUnit = au

        // Output enabled on element 0 (default); input disabled.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &enable, 4), "EnableIO output")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &disable, 4), "DisableIO input")

        var dev = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Set current device")

        // Client format we supply on input scope of element 0:
        // planar Float32 stereo at the device nominal rate.
        var fmt = planarFloatASBD(sampleRate: rate, channels: channelCount)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "Set output client format")

        var maxSlice = UInt32(maxFrames)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0, &maxSlice, 4), "Set max frames")

        let ctx = RenderContext(channelCount: channelCount, handler: mixHandler)
        self.context = ctx
        var callback = AURenderCallbackStruct(
            inputProc: halOutputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque()
        )
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Set render callback")

        try check(AudioUnitInitialize(au), "AudioUnitInitialize(output)")
    }

    var renderCallbackCount: Int { context?.callbackCount.load(ordering: .relaxed) ?? 0 }
    var lastRenderFrameCount: Int { context?.lastFrameCount.load(ordering: .relaxed) ?? 0 }
    var maxRenderFrameCount: Int { context?.maxFrameCount.load(ordering: .relaxed) ?? 0 }
    #if DEBUG
    var renderHandlerTicks: Int { context?.handlerTicks.load(ordering: .relaxed) ?? 0 }
    var maxRenderHandlerTicks: Int { context?.maxHandlerTicks.load(ordering: .relaxed) ?? 0 }
    #endif

    func start() throws {
        guard let au = audioUnit else { return }
        try check(AudioOutputUnitStart(au), "AudioOutputUnitStart(output)")
    }

    func stop() {
        guard let au = audioUnit else { return }
        AudioOutputUnitStop(au)
    }

    deinit {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
    }
}

/// C render callback: hand planar destination pointers to the mix handler.
private func halOutputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let ctx = Unmanaged<HALOutputUnit.RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    let frames = Int(inNumberFrames)
    ctx.callbackCount.wrappingAdd(1, ordering: .relaxed)
    ctx.lastFrameCount.store(frames, ordering: .relaxed)
    if frames > ctx.maxFrameCount.load(ordering: .relaxed) {
        ctx.maxFrameCount.store(frames, ordering: .relaxed)
    }
    let buffers = min(abl.count, ctx.channelCount)
    guard buffers == ctx.channelCount else {
        for b in 0..<abl.count {
            if let data = abl[b].mData { memset(data, 0, Int(abl[b].mDataByteSize)) }
        }
        return noErr
    }

    for c in 0..<ctx.channelCount {
        guard let data = abl[c].mData else { return noErr }
        ctx.dest[c] = data.assumingMemoryBound(to: Float.self)
    }

    #if DEBUG
    let startTicks = mach_absolute_time()
    #endif
    ctx.handler(UnsafePointer(ctx.dest), frames)
    #if DEBUG
    let elapsedTicks = Int(mach_absolute_time() - startTicks)
    ctx.handlerTicks.wrappingAdd(elapsedTicks, ordering: .relaxed)
    if elapsedTicks > ctx.maxHandlerTicks.load(ordering: .relaxed) {
        ctx.maxHandlerTicks.store(elapsedTicks, ordering: .relaxed)
    }
    #endif
    return noErr
}
