import Foundation

struct MixerSnapshot: Codable, Equatable {
    var inputs: [MixerConfiguration.InputStripConfig]
    var mainOutput: MixerConfiguration.OutputStripConfig

    init(configuration: MixerConfiguration) {
        inputs = configuration.inputs
        mainOutput = configuration.mainOutput
    }

    func validate() throws {
        guard inputs.count == MixerConfiguration.default.inputs.count else {
            throw ProfileError.invalidData("This profile has an unsupported number of input strips.")
        }
        func validGain(_ gain: Float) -> Bool {
            gain == -.infinity || (gain.isFinite && (FaderTaper.minDB...FaderTaper.maxDB).contains(gain))
        }
        guard validGain(mainOutput.gainDB), inputs.allSatisfy({
            $0.leftChannelIndex >= 0 && $0.leftChannelIndex < Int.max &&
            $0.rightChannelIndex >= 0 && $0.rightChannelIndex < Int.max &&
            validGain($0.gainDB) && $0.pan.isFinite && (-1...1).contains($0.pan)
        }) else {
            throw ProfileError.invalidData("This profile contains invalid channels, gains, or pan values.")
        }
    }

    func resolve(inputDevices: [AudioDevice], outputDevices: [AudioDevice]) -> ResolvedMixerSnapshot {
        let resolvedInputs = inputs.map { config -> AudioDevice in
            guard let device = inputDevices.first(where: { $0.uid == config.deviceUID && $0.isInput }),
                  config.leftChannelIndex < device.inputChannelCount,
                  config.rightChannelIndex < device.inputChannelCount else { return .none }
            return device
        }
        let output = outputDevices.first { $0.uid == mainOutput.deviceUID && $0.isOutput } ?? .none
        return ResolvedMixerSnapshot(inputs: resolvedInputs, output: output)
    }
}

struct ResolvedMixerSnapshot: Equatable {
    var inputs: [AudioDevice]
    var output: AudioDevice
}

struct MixerProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var saved: MixerSnapshot
    var draft: MixerSnapshot

    var isEdited: Bool { saved != draft }
}

enum ProfileError: LocalizedError {
    case invalidData(String)
    case invalidName(String)
    case noActiveProfile
    case missingProfile

    var errorDescription: String? {
        switch self {
        case .invalidData(let message), .invalidName(let message): return message
        case .noActiveProfile: return "No profile is selected."
        case .missingProfile: return "This profile no longer exists."
        }
    }
}

/// Profiles plus the profile-less working mix ("Default"). Default autosaves
/// like the original single configuration and is never reported as edited.
struct MixerProfileLibrary: Codable, Equatable {
    static let currentVersion = 2
    static let defaultName = "Default"

    var version = Self.currentVersion
    private(set) var profiles: [MixerProfile]
    private(set) var activeID: UUID?
    private(set) var defaultMix: MixerSnapshot
    var deviceNames: [String: String] = [:]

    var active: MixerProfile? { activeID.flatMap { id in profiles.first { $0.id == id } } }
    var currentDraft: MixerSnapshot { active?.draft ?? defaultMix }
    var isEdited: Bool { active?.isEdited ?? false }

    init(configuration: MixerConfiguration) {
        profiles = []
        activeID = nil
        defaultMix = MixerSnapshot(configuration: configuration)
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, activeID, defaultMix, deviceNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        profiles = try container.decode([MixerProfile].self, forKey: .profiles)
        activeID = try container.decodeIfPresent(UUID.self, forKey: .activeID)
        deviceNames = try container.decodeIfPresent([String: String].self, forKey: .deviceNames) ?? [:]
        if version == 1 {
            // Version 1 always had an active profile; its migrated "Default" profile becomes the working mix.
            guard let activeID, let active = profiles.first(where: { $0.id == activeID }) else {
                throw ProfileError.invalidData("The profile library has invalid profile references.")
            }
            if let legacy = profiles.first(where: { $0.name == Self.defaultName }) {
                defaultMix = legacy.draft
                profiles.removeAll { $0.id == legacy.id }
                if legacy.id == activeID { self.activeID = nil }
            } else {
                defaultMix = active.draft
            }
            version = Self.currentVersion
        } else {
            defaultMix = try container.decode(MixerSnapshot.self, forKey: .defaultMix)
        }
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw ProfileError.invalidData("These profiles were saved by an unsupported version of Faderline.")
        }
        guard Set(profiles.map(\.id)).count == profiles.count,
              activeID == nil || profiles.contains(where: { $0.id == activeID }) else {
            throw ProfileError.invalidData("The profile library has invalid profile references.")
        }
        try defaultMix.validate()
        for profile in profiles {
            guard try validatedName(profile.name, excluding: profile.id) == profile.name else {
                throw ProfileError.invalidName("Profile names must not start or end with whitespace.")
            }
            try profile.saved.validate()
            try profile.draft.validate()
        }
    }

    func validatedName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.invalidName("Enter a profile name.") }
        func same(_ other: String) -> Bool {
            other.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !same(Self.defaultName) else {
            throw ProfileError.invalidName("“\(Self.defaultName)” is reserved for the mix without a profile.")
        }
        guard !profiles.contains(where: { $0.id != id && same($0.name) }) else {
            throw ProfileError.invalidName("A profile with this name already exists.")
        }
        return trimmed
    }

    private func activeIndex() throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { throw ProfileError.noActiveProfile }
        return index
    }

    mutating func updateDraft(_ snapshot: MixerSnapshot) throws {
        try snapshot.validate()
        if let index = try? activeIndex() {
            profiles[index].draft = snapshot
        } else {
            defaultMix = snapshot
        }
    }

    /// Selects a profile, or Default when `id` is nil.
    mutating func select(_ id: UUID?) throws {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { throw ProfileError.missingProfile }
        activeID = id
    }

    mutating func save() throws {
        let index = try activeIndex()
        profiles[index].saved = profiles[index].draft
    }

    mutating func saveAs(_ name: String) throws {
        let name = try validatedName(name)
        let profile = MixerProfile(id: UUID(), name: name, saved: currentDraft, draft: currentDraft)
        profiles.append(profile)
        activeID = profile.id
    }

    mutating func rename(_ name: String) throws {
        let index = try activeIndex()
        profiles[index].name = try validatedName(name, excluding: activeID)
    }

    mutating func revert() throws {
        let index = try activeIndex()
        profiles[index].draft = profiles[index].saved
    }

    mutating func delete(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ProfileError.missingProfile }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
}

final class MixerProfileStore {
    static let storageKey = "MixerProfiles"
    static let latencyKey = "MixerLowLatencyModeEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> MixerProfileLibrary {
        if defaults.object(forKey: Self.storageKey) != nil {
            guard let data = defaults.data(forKey: Self.storageKey) else {
                throw ProfileError.invalidData("The stored profile library is not readable.")
            }
            let library = try MixerConfiguration.makeDecoder().decode(MixerProfileLibrary.self, from: data)
            try library.validate()
            return library
        }

        let configuration: MixerConfiguration
        if defaults.object(forKey: MixerConfiguration.storageKey) != nil {
            guard let data = defaults.data(forKey: MixerConfiguration.storageKey) else {
                throw ProfileError.invalidData("The existing mixer configuration is not readable.")
            }
            configuration = try MixerConfiguration.makeDecoder().decode(MixerConfiguration.self, from: data)
        } else {
            configuration = .default
        }
        let library = MixerProfileLibrary(configuration: configuration)
        try save(library)
        if defaults.object(forKey: Self.latencyKey) == nil {
            defaults.set(configuration.lowLatencyModeEnabled, forKey: Self.latencyKey)
        }
        return library
    }

    func save(_ library: MixerProfileLibrary) throws {
        try library.validate()
        let data = try MixerConfiguration.makeEncoder().encode(library)
        defaults.set(data, forKey: Self.storageKey)
    }

    var lowLatencyModeEnabled: Bool {
        get { defaults.bool(forKey: Self.latencyKey) }
        set { defaults.set(newValue, forKey: Self.latencyKey) }
    }
}
