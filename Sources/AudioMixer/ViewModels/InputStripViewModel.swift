import SwiftUI

/// ViewModel for a single input strip.
@Observable
final class InputStripViewModel: Identifiable {
    let id: Int
    let label: String

    var selectedDevice: AudioDevice = .none
    var leftChannelIndex: Int = 0
    var rightChannelIndex: Int = 1
    var volume: Float = 1.0
    var boostEnabled: Bool = false
    var routeToMain: Bool = true

    // Level metering
    var levelLeft: Float = 0
    var levelRight: Float = 0

    /// Effective volume including boost (+6 dB ≈ ×2.0).
    var effectiveVolume: Float {
        boostEnabled ? min(volume * 2.0, 2.0) : volume
    }

    /// Available channels for the selected device.
    var availableChannels: [AudioChannel] {
        selectedDevice.inputChannels
    }

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
