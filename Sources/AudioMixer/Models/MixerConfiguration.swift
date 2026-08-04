import Foundation

/// Persisted mixer state: which devices/channels are selected, volumes, and routing.
struct MixerConfiguration: Codable {
    var inputs: [InputStripConfig]
    var monitorOutput: OutputStripConfig
    var lowLatencyModeEnabled: Bool
    /// Whether the post-mix bus is also sent to `monitorOutput`'s selected
    /// hardware device. The virtual microphone feed (when the driver is
    /// installed) is unaffected by this toggle — it always receives the mix.
    var monitoringEnabled: Bool

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

    init(inputs: [InputStripConfig], monitorOutput: OutputStripConfig, lowLatencyModeEnabled: Bool = false, monitoringEnabled: Bool = true) {
        self.inputs = inputs
        self.monitorOutput = monitorOutput
        self.lowLatencyModeEnabled = lowLatencyModeEnabled
        self.monitoringEnabled = monitoringEnabled
    }

    static let `default` = MixerConfiguration(
        inputs: [
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             volume: 1.0, boostEnabled: false, routeToMain: true),
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             volume: 1.0, boostEnabled: false, routeToMain: true),
        ],
        monitorOutput: OutputStripConfig(deviceUID: "")
    )

    private enum CodingKeys: String, CodingKey {
        case inputs
        case monitorOutput
        /// Pre-virtual-mic releases stored this under "mainOutput"; decode
        /// that key too so existing users don't lose their output selection.
        case mainOutputLegacy = "mainOutput"
        case lowLatencyModeEnabled
        case monitoringEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputs = try container.decode([InputStripConfig].self, forKey: .inputs)
        if let monitorOutput = try container.decodeIfPresent(OutputStripConfig.self, forKey: .monitorOutput) {
            self.monitorOutput = monitorOutput
        } else {
            self.monitorOutput = try container.decode(OutputStripConfig.self, forKey: .mainOutputLegacy)
        }
        self.lowLatencyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .lowLatencyModeEnabled) ?? false
        self.monitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(monitorOutput, forKey: .monitorOutput)
        try container.encode(lowLatencyModeEnabled, forKey: .lowLatencyModeEnabled)
        try container.encode(monitoringEnabled, forKey: .monitoringEnabled)
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
