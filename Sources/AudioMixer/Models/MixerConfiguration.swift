import Foundation

/// Persisted mixer state: which devices/channels are selected, volumes, and routing.
struct MixerConfiguration: Codable {
    var inputs: [InputStripConfig]
    var mainOutput: OutputStripConfig
    var lowLatencyModeEnabled: Bool

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

    init(inputs: [InputStripConfig], mainOutput: OutputStripConfig, lowLatencyModeEnabled: Bool = false) {
        self.inputs = inputs
        self.mainOutput = mainOutput
        self.lowLatencyModeEnabled = lowLatencyModeEnabled
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

    private enum CodingKeys: String, CodingKey {
        case inputs
        case mainOutput
        case lowLatencyModeEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputs = try container.decode([InputStripConfig].self, forKey: .inputs)
        self.mainOutput = try container.decode(OutputStripConfig.self, forKey: .mainOutput)
        self.lowLatencyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .lowLatencyModeEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(mainOutput, forKey: .mainOutput)
        try container.encode(lowLatencyModeEnabled, forKey: .lowLatencyModeEnabled)
    }

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
