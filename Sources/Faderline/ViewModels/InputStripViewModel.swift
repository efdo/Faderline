import SwiftUI

/// Fast-changing meter state kept separate from strip controls so level
/// updates do not invalidate the whole channel strip.
@Observable
final class MeterViewModel {
    var levelLeft: Float = 0
    var levelRight: Float = 0
    var peakLeft: Float = 0
    var peakRight: Float = 0
    /// Latched once a drained peak hits 0 dBFS; cleared by tapping the clip LED.
    var clipped: Bool = false
    /// Shared meter redraw timestamp, advanced by `MixerViewModel`'s polling timer.
    var timestamp: Date = .now
}

/// ViewModel for a single input strip.
@Observable
final class InputStripViewModel: Identifiable {
    enum ChannelMode: String, CaseIterable, Identifiable {
        case mono1
        case mono2
        case stereo12

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mono1: "1 (Mono)"
            case .mono2: "2 (Mono)"
            case .stereo12: "1 - 2 (Stereo)"
            }
        }
    }

    let id: Int
    let label: String

    var selectedDevice: AudioDevice = .none
    var leftChannelIndex: Int = 0
    var rightChannelIndex: Int = 1
    /// Fader position in dB (see `FaderTaper`) — source of truth for gain.
    var gainDB: Float = 0
    /// Balance/pan in `[-1, +1]`; 0 is center.
    var pan: Float = 0
    var muted: Bool = false
    var soloed: Bool = false
    var routeToMain: Bool = true
    let meter = MeterViewModel()

    /// Linear gain for the current fader position. See `FaderTaper`.
    var gain: Float { FaderTaper.gain(forDB: gainDB) }

    /// Fader cap position (0...1) for the current dB value.
    var faderPosition: Float { FaderTaper.position(forDB: gainDB) }

    var hasDevice: Bool { selectedDevice.id != AudioDevice.none.id }

    /// Available channels for the selected device.
    var availableChannels: [AudioChannel] {
        selectedDevice.inputChannels
    }

    var availableChannelModes: [ChannelMode] {
        let count = selectedDevice.inputChannelCount
        if count <= 0 { return [] }
        if count == 1 { return [.mono1] }
        return [.mono1, .mono2, .stereo12]
    }

    var channelMode: ChannelMode {
        if leftChannelIndex == 0 && rightChannelIndex == 1 {
            return .stereo12
        }
        if leftChannelIndex == 1 && rightChannelIndex == 1 {
            return .mono2
        }
        return .mono1
    }

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
