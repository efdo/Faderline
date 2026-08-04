import SwiftUI

/// ViewModel for a single input strip.
@Observable
final class InputStripViewModel: Identifiable {
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

    // Level metering (pre-fader/pre-pan/pre-route RMS, so it shows the raw
    // source and still moves even when muted).
    var levelLeft: Float = 0
    var levelRight: Float = 0
    // Peak-hold metering.
    var peakLeft: Float = 0
    var peakRight: Float = 0
    /// Latched once a drained peak hits 0 dBFS; cleared by tapping the clip LED.
    var clipped: Bool = false

    /// Linear gain for the current fader position. See `FaderTaper`.
    var gain: Float { FaderTaper.gain(forDB: gainDB) }

    /// Fader cap position (0...1) for the current dB value.
    var faderPosition: Float { FaderTaper.position(forDB: gainDB) }

    /// Available channels for the selected device.
    var availableChannels: [AudioChannel] {
        selectedDevice.inputChannels
    }

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
