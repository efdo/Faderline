import Foundation

/// Describes a single channel within an audio device.
struct AudioChannel: Identifiable, Hashable {
    let index: Int
    let label: String

    var id: Int { index }
}
