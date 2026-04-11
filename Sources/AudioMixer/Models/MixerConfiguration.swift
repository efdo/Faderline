import Foundation

/// Persisted mixer state: which devices/channels are selected, volumes, and routing.
struct MixerConfiguration: Codable {
    var inputs: [InputStripConfig]
    var mainOutput: OutputStripConfig

    struct InputStripConfig: Codable {
        var deviceUID: String
        var leftChannelIndex: Int
        var rightChannelIndex: Int
        var volume: Float
        var boostEnabled: Bool
        var routeToMain: Bool
    }

    struct OutputStripConfig: Codable {
        var deviceUID: String
    }

    static let `default` = MixerConfiguration(
        inputs: [
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             volume: 1.0, boostEnabled: false, routeToMain: true),
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             volume: 1.0, boostEnabled: false, routeToMain: true),
        ],
        mainOutput: OutputStripConfig(deviceUID: "")
    )

    // MARK: - Persistence

    private static let storageKey = "MixerConfiguration"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> MixerConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(MixerConfiguration.self, from: data)
        else {
            return .default
        }
        return config
    }
}
