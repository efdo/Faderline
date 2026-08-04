import SwiftUI

/// ViewModel for the main output strip.
@Observable
final class OutputStripViewModel: Identifiable {
    let id: Int
    let label: String

    var selectedDevice: AudioDevice = .none
    /// Master fader position in dB (see `FaderTaper`).
    var gainDB: Float = 0
    var muted: Bool = false

    // Level metering (post-mix RMS; peak is measured pre-limiter).
    var levelLeft: Float = 0
    var levelRight: Float = 0
    var peakLeft: Float = 0
    var peakRight: Float = 0
    /// Latched once a drained peak hits 0 dBFS; cleared by tapping the clip LED.
    var clipped: Bool = false

    /// Linear gain for the current fader position. See `FaderTaper`.
    var gain: Float { FaderTaper.gain(forDB: gainDB) }

    /// Fader cap position (0...1) for the current dB value.
    var faderPosition: Float { FaderTaper.position(forDB: gainDB) }

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
