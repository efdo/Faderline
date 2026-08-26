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
    let meter = MeterViewModel()

    /// Linear gain for the current fader position. See `FaderTaper`.
    var gain: Float { FaderTaper.gain(forDB: gainDB) }

    /// Fader cap position (0...1) for the current dB value.
    var faderPosition: Float { FaderTaper.position(forDB: gainDB) }

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
