import Foundation
import CoreAudio
import Combine

/// Enumerates system audio devices and watches for hot-plug events.
@Observable
final class DeviceManager {
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installHotPlugListener()
    }

    deinit {
        removeHotPlugListener()
    }

    // MARK: - Public

    func refresh() {
        let allDevices = Self.allDevices()
        inputDevices = allDevices.filter(\.isInput)
        outputDevices = allDevices.filter(\.isOutput)
    }

    func device(forUID uid: String) -> AudioDevice? {
        let all = Self.allDevices()
        return all.first { $0.uid == uid }
    }

    // MARK: - Hot-plug listener

    private func installHotPlugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        self.listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeHotPlugListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - CoreAudio enumeration

    private static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { buildDevice(id: $0) }
    }

    private static func buildDevice(id: AudioDeviceID) -> AudioDevice? {
        guard let name = getStringProperty(id: id, selector: kAudioObjectPropertyName),
              let uid = getStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
        else { return nil }

        let inputChannels = channelCount(id: id, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = channelCount(id: id, scope: kAudioObjectPropertyScopeOutput)
        let sampleRate = getSampleRate(id: id)

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            sampleRate: sampleRate
        )
    }

    private static func getStringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr else { return nil }

        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &value) == noErr,
              let cfString = value?.takeRetainedValue()
        else { return nil }
        return cfString as String
    }

    private static func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferListPointer) == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func getSampleRate(id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 44100
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &sampleRate)
        return sampleRate
    }
}
