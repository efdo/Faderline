import Foundation

/// Persisted mixer state: which devices/channels are selected, gains, pan, and routing.
struct MixerConfiguration: Codable {
    var inputs: [InputStripConfig]
    var mainOutput: OutputStripConfig
    var lowLatencyModeEnabled: Bool

    struct InputStripConfig: Codable {
        var deviceUID: String
        var leftChannelIndex: Int
        var rightChannelIndex: Int
        /// Fader position in dB (see `FaderTaper`). Source of truth for gain;
        /// replaces the pre-console `volume`/`boostEnabled` pair below.
        var gainDB: Float
        /// Balance/pan in `[-1, +1]`; 0 is center.
        var pan: Float
        var muted: Bool
        var routeToMain: Bool

        init(deviceUID: String, leftChannelIndex: Int, rightChannelIndex: Int,
             gainDB: Float, pan: Float = 0, muted: Bool = false, routeToMain: Bool) {
            self.deviceUID = deviceUID
            self.leftChannelIndex = leftChannelIndex
            self.rightChannelIndex = rightChannelIndex
            self.gainDB = gainDB
            self.pan = pan
            self.muted = muted
            self.routeToMain = routeToMain
        }

        private enum CodingKeys: String, CodingKey {
            case deviceUID, leftChannelIndex, rightChannelIndex, gainDB, pan, muted, routeToMain
            // Pre-console fields, decoded only for one-time migration below.
            case volume, boostEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceUID = try container.decode(String.self, forKey: .deviceUID)
            leftChannelIndex = try container.decode(Int.self, forKey: .leftChannelIndex)
            rightChannelIndex = try container.decode(Int.self, forKey: .rightChannelIndex)
            routeToMain = try container.decode(Bool.self, forKey: .routeToMain)
            pan = try container.decodeIfPresent(Float.self, forKey: .pan) ?? 0
            muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false

            if let storedGainDB = try container.decodeIfPresent(Float.self, forKey: .gainDB) {
                gainDB = storedGainDB
            } else {
                // Migrate from the pre-console linear 0...1 volume slider plus
                // a +6 dB boost toggle: gain = volume * (boostEnabled ? 2 : 1).
                let legacyVolume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
                let legacyBoost = try container.decodeIfPresent(Bool.self, forKey: .boostEnabled) ?? false
                let legacyGain = legacyVolume * (legacyBoost ? 2 : 1)
                let migratedDB = FaderTaper.db(forGain: legacyGain)
                if migratedDB.isInfinite {
                    // True silence (volume was exactly 0) stays -infinity —
                    // the fader's hard "off" — rather than being clamped up
                    // into an audible -60 dB.
                    gainDB = migratedDB
                } else {
                    gainDB = min(max(migratedDB, FaderTaper.minDB), FaderTaper.maxDB)
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deviceUID, forKey: .deviceUID)
            try container.encode(leftChannelIndex, forKey: .leftChannelIndex)
            try container.encode(rightChannelIndex, forKey: .rightChannelIndex)
            try container.encode(gainDB, forKey: .gainDB)
            try container.encode(pan, forKey: .pan)
            try container.encode(muted, forKey: .muted)
            try container.encode(routeToMain, forKey: .routeToMain)
        }
    }

    struct OutputStripConfig: Codable {
        var deviceUID: String
        /// Master fader position in dB (see `FaderTaper`).
        var gainDB: Float

        init(deviceUID: String, gainDB: Float = 0) {
            self.deviceUID = deviceUID
            self.gainDB = gainDB
        }

        private enum CodingKeys: String, CodingKey {
            case deviceUID, gainDB
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceUID = try container.decode(String.self, forKey: .deviceUID)
            gainDB = try container.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deviceUID, forKey: .deviceUID)
            try container.encode(gainDB, forKey: .gainDB)
        }
    }

    init(inputs: [InputStripConfig], mainOutput: OutputStripConfig, lowLatencyModeEnabled: Bool = false) {
        self.inputs = inputs
        self.mainOutput = mainOutput
        self.lowLatencyModeEnabled = lowLatencyModeEnabled
    }

    static let `default` = MixerConfiguration(
        inputs: [
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             gainDB: 0, routeToMain: true),
            InputStripConfig(deviceUID: "", leftChannelIndex: 0, rightChannelIndex: 1,
                             gainDB: 0, routeToMain: true),
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

    /// `gainDB` can be `-.infinity` (fader parked at true silence). Standard
    /// JSON doesn't support non-finite numbers, so both the encoder and
    /// decoder must opt in to Foundation's string-based workaround.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    func save() {
        guard let data = try? Self.makeEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func load() -> MixerConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? makeDecoder().decode(MixerConfiguration.self, from: data)
        else {
            return .default
        }
        return config
    }
}

