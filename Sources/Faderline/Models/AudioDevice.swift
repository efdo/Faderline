import Foundation
import CoreAudio

/// Represents a system audio device (input or output).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let sampleRate: Double

    var isInput: Bool { inputChannelCount > 0 }
    var isOutput: Bool { outputChannelCount > 0 }

    /// Returns descriptors for available input channels.
    var inputChannels: [AudioChannel] {
        (0..<inputChannelCount).map { AudioChannel(index: $0, label: "Ch \($0 + 1)") }
    }

    /// Returns descriptors for available output channels.
    var outputChannels: [AudioChannel] {
        (0..<outputChannelCount).map { AudioChannel(index: $0, label: "Ch \($0 + 1)") }
    }
}

extension AudioDevice {
    static func unavailable(uid: String, name: String) -> AudioDevice {
        AudioDevice(id: kAudioObjectUnknown, uid: uid, name: "\(name) (Unavailable)",
                    inputChannelCount: 0, outputChannelCount: 0, sampleRate: 0)
    }

    /// Placeholder representing no device selected.
    static let none = AudioDevice(
        id: kAudioObjectUnknown,
        uid: "",
        name: "Select…",
        inputChannelCount: 0,
        outputChannelCount: 0,
        sampleRate: 44100
    )
}
