import SwiftUI

/// ViewModel for an output strip.
@Observable
final class OutputStripViewModel: Identifiable {
    let id: Int
    let label: String

    var selectedDevice: AudioDevice = .none

    // Level metering
    var levelLeft: Float = 0
    var levelRight: Float = 0

    init(id: Int, label: String) {
        self.id = id
        self.label = label
    }
}
